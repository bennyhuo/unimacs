// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

#import "UMTCPSocket.h"

#include <fcntl.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#import <net/if.h>

#define CONNECTION_TIMEOUT 5.0
#define SEND_TIMEOUT 2.0

static void _cfsocketCallback(CFSocketRef inCFSocketRef, CFSocketCallBackType inType, CFDataRef inAddress, const void* inData, void* inContext);

@interface UMTCPSocket (Private)

- (void)_close:(BOOL)dropped;
- (OSStatus)_sendData:(CFDataRef)data;
- (void)_receivedData:(CFDataRef)data;
- (BOOL)_setupSocketAllowReuseAddress:(BOOL)allowReuseAddress activateRunLoop:(BOOL)activateRunLoop;
- (BOOL)_drainPendingDataBeforeClose;

- (void)_connectionAcceptedWithNativeSocket:(int)nativeSocket peerAddress:(CFDataRef)peerAddress;
- (void)_connectionAcceptedWithChildSocket:(UMTCPSocket*)childSocket;
- (void)_connectionFailed;
- (void)_connectionSucceeded;
- (void)_connectionClosed;

@end

@implementation UMTCPSocket
{
	CFDataRef _peerAddressData;
	BOOL _runLoopDeferred;
}

- (instancetype) initWithDelegate:(id<UMTCPSocketDelegate>)delegate
{
	self = [super init];
	
	_delegate = delegate;
	_cfSocket = NULL;
	_runLoopRef = NULL;
	_sourceRef = NULL;
	_peerAddressData = NULL;
	_runLoopDeferred = NO;
	_socketState = TPSocketDisconnectedState;
	_noDelay = NO;
	_lock = [[NSLock alloc] init];
	
	return self;
}

- (void)setDelegate:(id<UMTCPSocketDelegate>)delegate
{
	_delegate = delegate;
}

- (id<UMTCPSocketDelegate>)delegate
{
	return _delegate;
}

- (void)setNoDelay:(BOOL)noDelay
{
	if(_noDelay != noDelay) {
		_noDelay = noDelay;
		
		[_lock lock];
		if (_cfSocket == NULL || !CFSocketIsValid(_cfSocket)) {
			[_lock unlock];
			return;
		}
		
		/* Setup socket flags */
		int socketOptionFlag = noDelay?1:0;
		int result = setsockopt(CFSocketGetNative(_cfSocket), IPPROTO_TCP, TCP_NODELAY, &socketOptionFlag, sizeof(int));
		if(result < 0) {
			DebugLog(@"error setting no delay (errno=%d)", errno);
			[_lock unlock];
			return;
		}
		
		if(noDelay) {
			socketOptionFlag = IPTOS_LOWDELAY | IPTOS_THROUGHPUT;
			int result = setsockopt(CFSocketGetNative(_cfSocket), IPPROTO_IP, IP_TOS, &socketOptionFlag, sizeof(socketOptionFlag));
			if(result < 0) {
				DebugLog(@"error setting low delay");
				[_lock unlock];
				return;
			}
		}
		else {
			/* Tweak for fast transfers */
//			int bufferSize = 32768;
//			int result = setsockopt(CFSocketGetNative(_cfSocket), SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(int));
//			if(result < 0) {
//				DebugLog(@"error setting send buffer");
//				[_lock unlock];
//				return;
//			}
//			
//			result = setsockopt(CFSocketGetNative(_cfSocket), SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(int));
//			if(result < 0) {
//				DebugLog(@"error setting receive buffer");
//				[_lock unlock];
//				return;
//			}
		}
		
		[_lock unlock];
	}
}
		
- (BOOL)_setupSocket
{
	return [self _setupSocketAllowReuseAddress:YES activateRunLoop:YES];
}

- (BOOL)_setupSocketAllowReuseAddress:(BOOL)allowReuseAddress
{
	return [self _setupSocketAllowReuseAddress:allowReuseAddress activateRunLoop:YES];
}

- (BOOL)_setupSocketAllowReuseAddress:(BOOL)allowReuseAddress activateRunLoop:(BOOL)activateRunLoop
{
	if(_cfSocket == NULL) {
		DebugLog(@"cfSocket is NULL");
		return NO;
	}
	
	if (allowReuseAddress) {
		/* SO_REUSEADDR is only valid before bind/listen; it fails on accepted connected sockets. */
		int socketOptionFlag = 1;
		int result = setsockopt(CFSocketGetNative(_cfSocket), SOL_SOCKET, SO_REUSEADDR, &socketOptionFlag, sizeof(int));
		if(result < 0) {
			DebugLog(@"error setting reusability of address (errno=%d)", errno);
			return NO;
		}
	}
	
	/* Enable TCP Keep-Alive to detect half-open connections quickly */
	int keepAliveOption = 1;
	setsockopt(CFSocketGetNative(_cfSocket), SOL_SOCKET, SO_KEEPALIVE, &keepAliveOption, sizeof(int));
	
	int keepAliveIdle = 15;
	setsockopt(CFSocketGetNative(_cfSocket), IPPROTO_TCP, TCP_KEEPALIVE, &keepAliveIdle, sizeof(int));
	
	int keepAliveIntvl = 5;
	setsockopt(CFSocketGetNative(_cfSocket), IPPROTO_TCP, TCP_KEEPINTVL, &keepAliveIntvl, sizeof(int));
	
	int keepAliveCnt = 3;
	setsockopt(CFSocketGetNative(_cfSocket), IPPROTO_TCP, TCP_KEEPCNT, &keepAliveCnt, sizeof(int));
	
	if (activateRunLoop) {
		[self _setRunLoop:CFRunLoopGetCurrent()];
	}
	
	return YES;
}

- (void)activateReceiveCallbacks
{
	if (!_runLoopDeferred || _cfSocket == NULL)
		return;
	
	_runLoopDeferred = NO;
	[self _setRunLoop:CFRunLoopGetCurrent()];
}

- (BOOL)listenOnPort:(int*)port tries:(int)tries
{
	int currentPort = *port;
	int currentTry = tries;
	
	while(--currentTry) {
		if([self listenOnPort:currentPort])
			break;
		else {
			[self _close:NO];
			currentPort++;
		}
	}
	
	if(currentTry > 0) {
		*port = currentPort;
		return YES;
	}
	else
		return NO;
}

- (BOOL)listenOnPort:(int)port
{
	OSStatus err;
	
	/* Setup context */
	CFSocketContext socketContext;
	bzero(&socketContext, sizeof(CFSocketContext));
	socketContext.info = (__bridge void *)(self);
	
	/* Create socket */
	_cfSocket = CFSocketCreate(kCFAllocatorDefault,
							  AF_INET, 
							  SOCK_STREAM, 
							  IPPROTO_TCP, 
							  kCFSocketAcceptCallBack, 
							  &_cfsocketCallback, 
							  &socketContext
							  );

	if(![self _setupSocket])
		return NO;
	
	/* Setup struct sockaddr */
	struct sockaddr_in address;
	address.sin_family = AF_INET;
	
	NSString *localIpAddress = [NetworkConfigurationWatcher shared].selectedLocalIpAddress;
	if (inet_pton(AF_INET, localIpAddress.cString, &address.sin_addr) <= 0) {
		perror("inet_pton failed");
		return NO;
	}

	address.sin_port = htons(port);
	
	CFDataRef addr = CFDataCreate(kCFAllocatorDefault, (void*)&address, sizeof(struct sockaddr_in));
	if((err = CFSocketSetAddress(_cfSocket, addr)) != kCFSocketSuccess) {
		CFRelease(addr);
		DebugLog(@"listen error: %d", errno);
		return NO;
	}
	
	CFRelease(addr);
	
#if DEBUG_SOCKET
	DebugLog(@"%@ listening on port %d", self, port);
#endif
	
	_socketState = TPSocketListeningState;
	
	return YES;
}

- (BOOL)connectToHost:(NSString*)host onPort:(int)port
{
	DebugLog(@"connect to %@ on port %d", host, port);
	
	if(host == nil) {
		ErrorLog(@"trying to connect to nil host");
		return NO;
	}
	
	/* Setup context */
	CFSocketContext socketContext;
	bzero(&socketContext, sizeof(CFSocketContext));
	socketContext.info = (__bridge void *)(self);
	
	/* Create socket */
	_cfSocket = CFSocketCreate(kCFAllocatorDefault,
							  PF_INET, 
							  SOCK_STREAM, 
							  IPPROTO_TCP, 
							  kCFSocketDataCallBack|kCFSocketConnectCallBack|kCFSocketWriteCallBack,
							  &_cfsocketCallback, 
							  &socketContext
							  );
	
	if(![self _setupSocket])
		return NO;
	
	/* Auto re-enable callbacks */
	CFOptionFlags socketFlags = CFSocketGetSocketFlags(_cfSocket);
	socketFlags |= kCFSocketAutomaticallyReenableDataCallBack;
	CFSocketSetSocketFlags(_cfSocket, socketFlags);
	
	/* Setup struct sockaddr */
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons(port);

	const char *hostCString = [host UTF8String];
	if (hostCString == NULL || inet_pton(AF_INET, hostCString, &address.sin_addr) != 1) {
#if LEGACY_BUILD
		struct hostent * hp = gethostbyname([host cString]);
#else
		struct hostent * hp = gethostbyname([host cStringUsingEncoding:NSUTF8StringEncoding]);
#endif
		if(hp == 0) {
			ErrorLog(@"could not resolve host %@", host);
			[self _close:NO];
			return NO;
		}
		bcopy((char *)hp->h_addr, (char *)&address.sin_addr, hp->h_length);
	}
	
	/* Connect */
	CFDataRef addr = CFDataCreate(kCFAllocatorDefault, (void*)&address, sizeof(struct sockaddr_in));
	CFSocketError socketError = CFSocketConnectToAddress(_cfSocket, addr, CONNECTION_TIMEOUT);
	if (socketError != kCFSocketSuccess) {
		if(socketError == kCFSocketError) {
			int err = errno;
			DebugLog(@"Connection failed with errno: %d (%s)", err, strerror(err));
		} else if (socketError == kCFSocketTimeout) {
			DebugLog(@"Connection timeout.");
		}
		
		if(addr != NULL) {
			CFRelease(addr);
		}
		[self _close:NO];
		return NO;
	}
	
	if(addr != NULL) {
		CFRelease(addr);
	}

#if DEBUG_SOCKET
	DebugLog(@"%@ connecting to host %@ port %d", self, host, port);
#endif
	_socketState = TPSocketConnectingState;
	
	return YES;
}

- (void)setNativeSocket:(CFSocketNativeHandle)native
{
	[self setNativeSocket:native peerAddress:NULL];
}

- (void)setNativeSocket:(CFSocketNativeHandle)native peerAddress:(CFDataRef)peerAddress
{
	/* Setup context */
	CFSocketContext socketContext;
	bzero(&socketContext, sizeof(CFSocketContext));
	socketContext.info = (__bridge void *)(self);
	
	/* Create socket from native */
	_cfSocket = CFSocketCreateWithNative(kCFAllocatorDefault, 
										native, 
										kCFSocketDataCallBack|kCFSocketWriteCallBack, 
										&_cfsocketCallback, 
										&socketContext
										);
	
	if(_cfSocket == NULL) {
		ErrorLog(@"CFSocketCreateWithNative failed for accepted socket (errno=%d)", errno);
		return;
	}
	
	if (peerAddress != NULL) {
		if (_peerAddressData != NULL) {
			CFRelease(_peerAddressData);
		}
		_peerAddressData = CFDataCreateCopy(kCFAllocatorDefault, peerAddress);
	}
	
	_runLoopDeferred = YES;
	if(![self _setupSocketAllowReuseAddress:NO activateRunLoop:NO]) {
		ErrorLog(@"failed to configure accepted socket");
		_runLoopDeferred = NO;
		[self _close:NO];
		return;
	}
	
	/* Auto re-enable callbacks */
	CFOptionFlags socketFlags = CFSocketGetSocketFlags(_cfSocket);
	socketFlags |= kCFSocketAutomaticallyReenableDataCallBack;
	CFSocketSetSocketFlags(_cfSocket, socketFlags);
	
	_socketState = TPSocketConnectedState;
}

- (void)_setRunLoop:(CFRunLoopRef)runLoopRef
{
	[_lock lock];
	
	//DebugLog(@"socket: %@ _setRunLoop: %@ _runLoop: %@ _sourceRef: %@ current: %@", self, runLoopRef, _runLoopRef, _sourceRef, CFRunLoopGetCurrent());
	
	if(runLoopRef != NULL && _sourceRef == NULL && _cfSocket != NULL)
		_sourceRef = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _cfSocket, 0);
	else if(runLoopRef != _runLoopRef && _runLoopRef != NULL && _sourceRef != NULL) {
		//DebugLog(@"willRemoveSource");
		CFRunLoopRemoveSource(_runLoopRef, _sourceRef, kCFRunLoopCommonModes);
		//DebugLog(@"didRemoveSource");
	}
	
	//DebugLog(@"_sourceRef: %@", _sourceRef);
	
	_runLoopRef = runLoopRef;
	
	if(runLoopRef != NULL && _sourceRef != NULL) {
		CFRunLoopAddSource(runLoopRef, _sourceRef, kCFRunLoopCommonModes);
		//DebugLog(@"adding source %@ to runloop %@ in mode %@", _sourceRef, runLoopRef, kCFRunLoopCommonModes);
	}
	else if(runLoopRef == NULL && _sourceRef != NULL) {
		CFRelease(_sourceRef);
		_sourceRef = NULL;
	}
	
	[_lock unlock];
}

- (void)dealloc
{
	[self close];
}

- (NSString*)_stringAddressFromCFData:(CFDataRef)dataRef
{
	char buffer[256];
	
	if(dataRef == NULL)
		return nil;
	
	struct sockaddr * socketAddress = (struct sockaddr *)CFDataGetBytePtr(dataRef);

	if(socketAddress->sa_family != AF_INET)
		WarningLog(@"warning: address not AF_INET");

	if(inet_ntop(AF_INET, &((struct sockaddr_in *)socketAddress)->sin_addr, buffer, sizeof(buffer))) {
#if LEGACY_BUILD
		return [NSString stringWithCString:buffer];
#else
		return @(buffer);
#endif		
	}
	
	return nil;
}

- (NSString*)localAddress
{
	CFDataRef dataRef;
	[_lock lock];
	dataRef = _cfSocket ? CFSocketCopyAddress(_cfSocket) : NULL;
	[_lock unlock];
	
	if(dataRef != NULL) {
		NSString * localAddress = [self _stringAddressFromCFData:dataRef];
		CFRelease(dataRef);
		return localAddress;
	}
	else
		return nil;
}

- (NSString*)remoteAddress
{
	CFDataRef dataRef = NULL;
	CFSocketNativeHandle native = -1;
	[_lock lock];
	if (_cfSocket) {
		dataRef = CFSocketCopyPeerAddress(_cfSocket);
		native = CFSocketGetNative(_cfSocket);
	}
	if (dataRef == NULL && _peerAddressData != NULL) {
		dataRef = CFDataCreateCopy(kCFAllocatorDefault, _peerAddressData);
	}
	[_lock unlock];
	
	if(dataRef != NULL) {
		NSString *address = [self _stringAddressFromCFData:dataRef];
		CFRelease(dataRef);
		if (address != nil) {
			return address;
		}
	}
	
	if (native >= 0) {
		struct sockaddr_storage storage;
		socklen_t length = sizeof(storage);
		if (getpeername(native, (struct sockaddr *)&storage, &length) == 0 &&
			storage.ss_family == AF_INET) {
			char buffer[256];
			struct sockaddr_in *ipv4 = (struct sockaddr_in *)&storage;
			if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer))) {
				return @(buffer);
			}
		}
	}
	
	return nil;
}

- (CFSocketNativeHandle)nativeHandle
{
	return CFSocketGetNative(_cfSocket);
}

- (BOOL)sendData:(NSData*)data
{
#if DEBUG_SOCKET
	DebugLog(@"%@ sending data (%d)", self, [data length]);
#endif
	
	BOOL result = ([self _sendData:(CFDataRef)data] == noErr);
	
#if DEBUG_SOCKET
	DebugLog(@"%@ end sending data (%d): %d", self, [data length], result);
#endif
	
	return result;
}

- (OSStatus)_sendData:(CFDataRef)data
{
	CFSocketNativeHandle sock = -1;
	
	[_lock lock];
	if(_cfSocket == NULL || !CFSocketIsValid(_cfSocket)) {
		[_lock unlock];
		NetworkErrorLog(@"[Socket] _sendData failed: socket is NULL or invalid, state=%d", _socketState);
		return kCFSocketError;
	}
	
	sock = CFSocketGetNative(_cfSocket);
	CFSocketEnableCallBacks(_cfSocket, kCFSocketWriteCallBack);
	[_lock unlock];
	
	const uint8_t * dataptr = CFDataGetBytePtr(data);
	SInt32 datalen = CFDataGetLength(data);
	
	while(datalen > 0) {
		ssize_t sent = send(sock, dataptr, datalen, 0);
		if(sent > 0) {
			dataptr += sent;
			datalen -= (SInt32)sent;
			continue;
		}
		
		if(sent == 0) {
			NetworkWarningLog(@"[Socket] send() returned 0 (socket closed), local=%@, remote=%@", [self localAddress], [self remoteAddress]);
			return kCFSocketError;
		}
		
		// sent < 0
		int err = errno;
		if(err == EINTR) {
			continue;
		}
		
		if(err == EAGAIN || err == EWOULDBLOCK) {
			NetworkDebugLog(@"[Socket] send() blocked (EAGAIN/EWOULDBLOCK), waiting for writable, timeout=%.1fs", SEND_TIMEOUT);
			// Wait until the socket becomes writable, then retry.
			fd_set wfds;
			FD_ZERO(&wfds);
			FD_SET(sock, &wfds);
			struct timeval tv;
			tv.tv_sec = (int)SEND_TIMEOUT;
			tv.tv_usec = 0;
			int sel = select(sock + 1, NULL, &wfds, NULL, &tv);
			if(sel > 0) {
				NetworkDebugLog(@"[Socket] select() returned %d, socket became writable", sel);
				continue;
			}
			if(sel == 0) {
				NetworkErrorLog(@"[Socket] select() timeout after %.1fs, send blocked too long, local=%@, remote=%@", SEND_TIMEOUT, [self localAddress], [self remoteAddress]);
				return kCFSocketError;
			}
			NetworkErrorLog(@"[Socket] select() failed while sending data (errno=%d/%s), local=%@, remote=%@", errno, strerror(errno), [self localAddress], [self remoteAddress]);
			return kCFSocketError;
		}
		
		NetworkErrorLog(@"[Socket] Unable to send data (errno=%d/%s), local=%@, remote=%@", err, strerror(err), [self localAddress], [self remoteAddress]);
		return kCFSocketError;
	}
	
	return noErr;
}

- (TPSocketState)socketState
{
	return _socketState;
}

- (void)close
{
	[self setDelegate:nil];
	
	if(_socketState == TPSocketDisconnectedState)
		return;
	
	[_lock lock];
	CFRunLoopRef ownerRunLoop = _runLoopRef;
	[_lock unlock];
	
	// Run loop source removal must happen on the socket's owner run loop.
	if (ownerRunLoop != NULL && ownerRunLoop != CFRunLoopGetCurrent()) {
		dispatch_semaphore_t sem = dispatch_semaphore_create(0);
		__weak UMTCPSocket *weakSelf = self;
		CFRunLoopPerformBlock(ownerRunLoop, kCFRunLoopCommonModes, ^{
			UMTCPSocket *strongSelf = weakSelf;
			if (strongSelf != nil) {
				[strongSelf _close:NO];
			}
			dispatch_semaphore_signal(sem);
		});
		CFRunLoopWakeUp(ownerRunLoop);
		
		if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC))) != 0) {
			WarningLog(@"[Socket] owner run loop did not respond, forcing close");
			[self _forceCloseWithoutRunLoopCleanup:NO];
		}
		return;
	}
	
	[self _close:NO];
}

- (void)_forceCloseWithoutRunLoopCleanup:(BOOL)dropped
{
	if(_socketState == TPSocketDisconnectedState)
		return;
	
	TPSocketState previousState = _socketState;
	_socketState = TPSocketDisconnectedState;
	
	NetworkDebugLog(@"[Socket] _forceCloseWithoutRunLoopCleanup: dropped=%@, previousState=%d, local=%@, remote=%@", dropped?@"YES":@"NO", previousState, [self localAddress], [self remoteAddress]);
	
	if(_cfSocket != NULL) {
		[_lock lock];
		if (CFSocketIsValid(_cfSocket)) {
			CFSocketInvalidate(_cfSocket);
		}
		CFRelease(_cfSocket);
		_cfSocket = NULL;
		[_lock unlock];
	}
	
	[_lock lock];
	if (_sourceRef != NULL) {
		CFRelease(_sourceRef);
		_sourceRef = NULL;
	}
	if (_peerAddressData != NULL) {
		CFRelease(_peerAddressData);
		_peerAddressData = NULL;
	}
	_runLoopRef = NULL;
	[_lock unlock];
}

- (void)_close:(BOOL)dropped
{
	TPSocketState previousState = _socketState;
	_socketState = TPSocketDisconnectedState;

	NetworkDebugLog(@"[Socket] _close: dropped=%@, previousState=%d, local=%@, remote=%@", dropped?@"YES":@"NO", previousState, [self localAddress], [self remoteAddress]);

#if DEBUG_SOCKET
	DebugLog(@"socket %@ %@", self, dropped?@"dropped":@"closed");
#endif

	[self _setRunLoop:NULL];
	if(_cfSocket != NULL) {
		[_lock lock];
		CFSocketInvalidate(_cfSocket);
		CFRelease(_cfSocket);
		_cfSocket = NULL;
		[_lock unlock];
	}
	
	[_lock lock];
	if (_peerAddressData != NULL) {
		CFRelease(_peerAddressData);
		_peerAddressData = NULL;
	}
	[_lock unlock];
}

- (BOOL)_drainPendingDataBeforeClose
{
	[_lock lock];
	if (_cfSocket == NULL || !CFSocketIsValid(_cfSocket)) {
		[_lock unlock];
		return NO;
	}
	int native = CFSocketGetNative(_cfSocket);
	[_lock unlock];
	
	if (native < 0)
		return NO;
	
	int pending = 0;
	if (ioctl(native, FIONREAD, &pending) != 0 || pending <= 0)
		return NO;
	
	NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)pending];
	ssize_t received = recv(native, buffer.mutableBytes, (size_t)pending, 0);
	if (received <= 0)
		return NO;
	
	buffer.length = (NSUInteger)received;
	NetworkDebugLog(@"[Socket] drained %zd pending byte(s) before treating empty callback as close, local=%@, remote=%@", received, [self localAddress], [self remoteAddress]);
	[self _receivedData:(__bridge CFDataRef)buffer];
	return YES;
}

- (void)_receivedData:(CFDataRef)data
{
	if([_delegate respondsToSelector:@selector(tcpSocket:gotData:)])
		[_delegate tcpSocket:self gotData:(__bridge NSData*)data];
}

- (void)_didSendData
{
#if DEBUG_SOCKET
	DebugLog(@"%@ data sent", self);
#endif
	
	if([_delegate respondsToSelector:@selector(tcpSocketDidSendData:)])
		[_delegate tcpSocketDidSendData:self];
}

- (void)_connectionAcceptedWithNativeSocket:(int)nativeSocket peerAddress:(CFDataRef)peerAddress
{
	UMTCPSocket * childSocket = [[[self class] alloc] initWithDelegate:nil];
	[childSocket setNativeSocket:nativeSocket peerAddress:peerAddress];
	[self _connectionAcceptedWithChildSocket:childSocket];
}

- (void)_connectionAcceptedWithChildSocket:(UMTCPSocket*)childSocket
{
	if([_delegate respondsToSelector:@selector(tcpSocket:connectionAccepted:)])
		[_delegate tcpSocket:self connectionAccepted:childSocket];
}

- (void)_connectionFailed
{
	[self _close:NO];
	
	if([_delegate respondsToSelector:@selector(tcpSocketConnectionFailed:)])
		[_delegate tcpSocketConnectionFailed:self];
}

- (void)_connectionSucceeded
{
	PRINT_ME;
	_socketState = TPSocketConnectedState;
	
	if([_delegate respondsToSelector:@selector(tcpSocketConnectionSucceeded:)])
		[_delegate tcpSocketConnectionSucceeded:self];
}

- (void)_connectionClosed
{
	NetworkDebugLog(@"[Socket] _connectionClosed called, currentState=%d, local=%@, remote=%@", _socketState, [self localAddress], [self remoteAddress]);
	
	if(_socketState == TPSocketDisconnectedState)
		return;
	
	[self _close:YES];

	// keep a strong reference to prevent delegate(i.e. connection) from dealloc immediately.
	id delegate = _delegate;
	if([delegate respondsToSelector:@selector(tcpSocketConnectionClosed:)])
		[delegate tcpSocketConnectionClosed:self];
}

@end

void _cfsocketCallback(CFSocketRef inCFSocketRef, CFSocketCallBackType inType, CFDataRef inAddress, const void* inData, void* inContext)
{
	UMTCPSocket * tcpSocket = (__bridge UMTCPSocket*)inContext;

	if(!tcpSocket)
		return;

	switch(inType)
	{
		case kCFSocketDataCallBack:
		{
			if(inData == NULL || CFDataGetLength((CFDataRef)inData) == 0) {
				if ([tcpSocket _drainPendingDataBeforeClose])
					break;
				NetworkDebugLog(@"[Socket] CFSocketDataCallBack: received empty data (connection closed by peer), local=%@, remote=%@", [tcpSocket localAddress], [tcpSocket remoteAddress]);
				[tcpSocket _connectionClosed];
			} else {
				[tcpSocket _receivedData:(CFDataRef)inData];
			}
			break;
		}
		case kCFSocketAcceptCallBack:
		{
			int native = *((int*)inData);
			[tcpSocket _connectionAcceptedWithNativeSocket:native peerAddress:inAddress];
			break;
		}	
		case kCFSocketConnectCallBack:
		{
			if(inData == NULL) {
				NetworkDebugLog(@"[Socket] CFSocketConnectCallBack: connection succeeded, local=%@, remote=%@", [tcpSocket localAddress], [tcpSocket remoteAddress]);
				[tcpSocket _connectionSucceeded];
			} else {
				SInt32 errorCode = *((SInt32*)inData);
				NetworkErrorLog(@"[Socket] CFSocketConnectCallBack: connection failed, errorCode=%d (%s)", errorCode, strerror(errorCode));
				[tcpSocket _connectionFailed];
			}
			break;
		}
		case kCFSocketWriteCallBack:
		{
			[tcpSocket _didSendData];
			break;
		}
//		case kCFSocketWriteCallBack:
//		{
//			[tcpSocket _becameWritable];
//		}
		default:
			break;
	}
}


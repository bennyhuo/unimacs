//
//  TPTCPSocket.h
//  teleport
//
//  Created by JuL on Thu Jan 08 2004.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import <Foundation/Foundation.h>

#include <IOKit/network/IOEthernetController.h>

#import "TPTCPSocketDelegates.h"

#define DEBUG_SOCKET 0

#ifndef DebugLog
#define DebugLog(logString, args...) NSLog(logString , ##args)
#endif

@class IOEthernetAddress, TPTCPSocket;

typedef NS_ENUM(NSInteger, TPSocketState) {
	TPSocketDisconnectedState,
	TPSocketListeningState,
	TPSocketConnectingState,
	TPSocketConnectedState,
	TPSocketErrorState
} ;

@interface TPTCPSocket : NSObject
{
	id<TPTCPSocketDelegate> _delegate;
	
	CFSocketRef _cfSocket;
	CFRunLoopRef _runLoopRef;
	CFRunLoopSourceRef _sourceRef;
	
	BOOL _noDelay;
	NSLock * _lock;
	
	TPSocketState _socketState;
}

+ (BOOL)wakeUpHostWithMACAddress:(IOEthernetAddress*)macAddress;

- (instancetype) initWithDelegate:(id<TPTCPSocketDelegate>)delegate NS_DESIGNATED_INITIALIZER;

@property (nonatomic, unsafe_unretained) id<TPTCPSocketDelegate> delegate;

- (void)setNoDelay:(BOOL)noDelay;

- (BOOL)listenOnPort:(int*)port tries:(int)tries;
- (BOOL)listenOnPort:(int)port;
- (BOOL)connectToHost:(NSString*)host onPort:(int)port;
- (void)setNativeSocket:(CFSocketNativeHandle)native;

/// Attach the socket to the current run loop and begin delivering read callbacks.
/// For accepted sockets this must be called only after the delegate chain is ready.
- (void)activateReceiveCallbacks;

@property (nonatomic, readonly, copy) NSString *localAddress;
@property (nonatomic, readonly, copy) NSString *remoteAddress;
@property (nonatomic, readonly) CFSocketNativeHandle nativeHandle;

- (BOOL)sendData:(NSData*)data;
@property (nonatomic, readonly) TPSocketState socketState;
- (void)close;

- (void)_setRunLoop:(CFRunLoopRef)runLoop;

@end

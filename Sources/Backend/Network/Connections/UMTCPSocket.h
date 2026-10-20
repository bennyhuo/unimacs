// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

#import <Foundation/Foundation.h>

#include <IOKit/network/IOEthernetController.h>

#import "UMTCPSocketDelegates.h"

#define DEBUG_SOCKET 0

#ifndef DebugLog
#define DebugLog(logString, args...) NSLog(logString , ##args)
#endif

@class IOEthernetAddress, UMTCPSocket;

typedef NS_ENUM(NSInteger, TPSocketState) {
	TPSocketDisconnectedState,
	TPSocketListeningState,
	TPSocketConnectingState,
	TPSocketConnectedState,
	TPSocketErrorState
} ;

@interface UMTCPSocket : NSObject
{
	id<UMTCPSocketDelegate> _delegate;
	
	CFSocketRef _cfSocket;
	CFRunLoopRef _runLoopRef;
	CFRunLoopSourceRef _sourceRef;
	
	BOOL _noDelay;
	NSLock * _lock;
	
	TPSocketState _socketState;
}

- (instancetype) initWithDelegate:(id<UMTCPSocketDelegate>)delegate NS_DESIGNATED_INITIALIZER;

@property (nonatomic, unsafe_unretained) id<UMTCPSocketDelegate> delegate;

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

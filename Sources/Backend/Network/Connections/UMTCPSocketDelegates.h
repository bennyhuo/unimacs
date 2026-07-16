// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

#ifndef UMTCPSocketDelegates_h
#define UMTCPSocketDelegates_h

@class UMTCPSocket,UMTCPSecureSocket;

@protocol UMTCPSocketDelegate <NSObject>

@optional
- (void)tcpSocket:(UMTCPSocket*)tcpSocket gotData:(NSData*)data;
- (void)tcpSocketDidSendData:(UMTCPSocket*)tcpSocket;
- (void)tcpSocket:(UMTCPSocket*)listenSocket connectionAccepted:(UMTCPSocket*)childSocket;
- (void)tcpSocketConnectionSucceeded:(UMTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionFailed:(UMTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionClosed:(UMTCPSocket*)tcpSocket;

@end

@protocol UMTCPSecureSocketDelegate <NSObject, UMTCPSocketDelegate>

@optional
- (BOOL)tcpSecureSocketShouldEnableEncryption:(UMTCPSecureSocket*)tcpSocket;

@end

#endif /* UMTCPSocketDelegates_h */

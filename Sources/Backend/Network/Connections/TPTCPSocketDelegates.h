//
//  TPTCPSocketDelegates.h
//  teleport
//
//  Created by benny on 2025/12/30.
//

#ifndef TPTCPSocketDelegates_h
#define TPTCPSocketDelegates_h

@class TPTCPSocket,TPTCPSecureSocket;

@protocol TPTCPSocketDelegate <NSObject>

@optional
- (void)tcpSocket:(TPTCPSocket*)tcpSocket gotData:(NSData*)data;
- (void)tcpSocketDidSendData:(TPTCPSocket*)tcpSocket;
- (void)tcpSocket:(TPTCPSocket*)listenSocket connectionAccepted:(TPTCPSocket*)childSocket;
- (void)tcpSocketConnectionSucceeded:(TPTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionFailed:(TPTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionClosed:(TPTCPSocket*)tcpSocket;

@end

@protocol TPTCPSecureSocketDelegate <NSObject, TPTCPSocketDelegate>

@optional
- (BOOL)tcpSecureSocketShouldEnableEncryption:(TPTCPSecureSocket*)tcpSocket;

@end

#endif /* TPTCPSocketDelegates_h */

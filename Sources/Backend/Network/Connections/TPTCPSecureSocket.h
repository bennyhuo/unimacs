//
//  TPTCPSecureSocket.h
//  SecureMessaging
//
//  Created by JuL on 03/04/06.
//  Copyright 2006 abyssoft. All rights reserved.
//

#import "TPTCPSocket.h"

typedef NS_ENUM(NSInteger, TPSecureSocketState) {
	TPSecureSocketNormalState,
	TPSecureSocketHandshakingState
} ;

@interface TPTCPSecureSocket : TPTCPSocket
{
	SSLContextRef _contextRef;
	TPSecureSocketState _secureSocketState;
	TPTCPSecureSocket * _parentSocket;
	NSLock * _sslLock;
	
	CFMutableDataRef _encryptedDataRef;
}

@property (nonatomic, assign) BOOL enableEncryption;
@property (nonatomic, readonly) SecCertificateRef copyPeerCertificate;
@property (nonatomic, assign) id<TPTCPSecureSocketDelegate> secureDelegate;

NS_ASSUME_NONNULL_BEGIN
- (instancetype) initWithDelegate:(id<TPTCPSecureSocketDelegate>)delegate;
NS_ASSUME_NONNULL_END
@end

// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

#import "UMTCPSocket.h"

typedef NS_ENUM(NSInteger, TPSecureSocketState) {
	TPSecureSocketNormalState,
	TPSecureSocketHandshakingState
} ;

@interface UMTCPSecureSocket : UMTCPSocket
{
	SSLContextRef _contextRef;
	TPSecureSocketState _secureSocketState;
	UMTCPSecureSocket * _parentSocket;
	NSLock * _sslLock;
	
	CFMutableDataRef _encryptedDataRef;
}

@property (nonatomic, assign) BOOL enableEncryption;
@property (nonatomic, readonly) SecCertificateRef copyPeerCertificate;
@property (nonatomic, assign) id<UMTCPSecureSocketDelegate> secureDelegate;

NS_ASSUME_NONNULL_BEGIN
- (instancetype) initWithDelegate:(id<UMTCPSecureSocketDelegate>)delegate;
NS_ASSUME_NONNULL_END
@end

NS_ASSUME_NONNULL_BEGIN
@interface UMObjCExceptionCatcher : NSObject
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error NS_SWIFT_NAME(catchException(_:));
@end
NS_ASSUME_NONNULL_END


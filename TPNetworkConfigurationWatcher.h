//
//  TPNetworkConfigurationWatcher.h
//  teleport
//
//  Created by Julien Robert on 13/04/08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>

@interface TPNetworkConfigurationWatcher : NSObject
{
	SCDynamicStoreRef _storeRef;
	CFRunLoopSourceRef _sourceRef;
	
	id _delegate;
}

@property NSMutableArray<NSString *> *localIpAddresses;
@property NSString *selectedLocalIpAddress;

- (void)setDelegate:(id)delegate;

- (void)startWatching;
- (void)stopWatching;

-(void)selectLocalIpAddress: (NSString *)value;

@end

@interface NSObject (TPNetworkConfigurationWatcherDelegate)

- (void)networkConfigurationDidChange:(TPNetworkConfigurationWatcher*)watcher;

@end

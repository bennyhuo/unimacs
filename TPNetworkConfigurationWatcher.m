//
//  TPNetworkConfigurationWatcher.m
//  teleport
//
//  Created by Julien Robert on 13/04/08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "TPNetworkConfigurationWatcher.h"
#import "TPServerController.h"
#import "TPClientController.h"
#import "TPNetworkConnection.h"
#import "TPRemoteHost.h"

#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

#define LOCAL_IP_ANY_ADDR @"0.0.0.0"
#define LOCAL_IP_KEY @"localIpAddress"

static void _networkChangeCallBack(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info);

@implementation TPNetworkConfigurationWatcher

- (instancetype)init
{
	self = [super init];
	if (self) {
		self.localIpAddresses = [[NSMutableArray alloc] init];
		[self updateLocalIpAddresses];
		self.selectedLocalIpAddress = [[TPPreferencesManager sharedPreferencesManager] valueForKey:LOCAL_IP_KEY];
		if (!self.selectedLocalIpAddress) {
			self.selectedLocalIpAddress = LOCAL_IP_ANY_ADDR;
		}
	}
	return self;
}

- (void)setDelegate:(id)delegate
{
	_delegate = delegate;
}

- (void)startWatching
{
	SCDynamicStoreContext context = {
		0,			   // version
		(__bridge void *)(self),		   // info
		NULL,		   // retain
		NULL,		   // release
		NULL,		   // copyDescription
	};
	
	_storeRef = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("com.abyssoft.teleport"), &_networkChangeCallBack, &context);
	if(_storeRef == NULL) {
		NSLog(@"Error creating the dynamic store");
	}
	else {
		CFMutableArrayRef keys = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
		CFMutableArrayRef patterns = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
		CFStringRef key;
		
		/* watch for IPv4 configuration changes (e.g. new default route) */
		key = SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetIPv4);
		CFArrayAppendValue(keys, key);
		CFRelease(key);
		
		/* as above, but for IPv6 */
		key = SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetIPv6);
		CFArrayAppendValue(keys, key);
		CFRelease(key);
		
		/* watch for IPv4 interface configuration changes */
		key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4);
		CFArrayAppendValue(patterns, key);
		CFRelease(key);
		
		/* as above, but for IPv6 */
		key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv6);
		CFArrayAppendValue(patterns, key);
		CFRelease(key);
		
		/* watch for DNS interface configuration changes */
		key = SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetDNS);
		CFArrayAppendValue(keys, key);
		CFRelease(key);
		
        _sourceRef = SCDynamicStoreCreateRunLoopSource(NULL, _storeRef, 0);
        
        if(_sourceRef == NULL) {
            NSLog(@"Error creating the dynamic store runloop source");
        }
		else {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), _sourceRef, kCFRunLoopDefaultMode);
            
            if(!SCDynamicStoreSetNotificationKeys(_storeRef, (CFArrayRef)keys, (CFArrayRef)patterns)) {
                NSLog(@"Error setting the dynamic store notification keys");
            }
			
            CFRelease(_sourceRef);
		}
		
		CFRelease(keys);
		CFRelease(patterns);
	}
}

- (void)stopWatching
{
	if (_sourceRef) {
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _sourceRef, kCFRunLoopDefaultMode);
		CFRelease(_sourceRef);
		_sourceRef = NULL;
	}
}

- (void)_networkChanged
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_notifyNetworkChanged) object:nil];
	[self performSelector:@selector(_notifyNetworkChanged) withObject:nil afterDelay:1.0];
}

- (void)_notifyNetworkChanged
{
	if([_delegate respondsToSelector:@selector(networkConfigurationDidChange:)]) {
		[_delegate networkConfigurationDidChange:self];
	}
}

- (void)updateLocalIpAddresses
{
	[self.localIpAddresses removeAllObjects];
	[self.localIpAddresses addObject:LOCAL_IP_ANY_ADDR];
	
	struct ifaddrs *interfaces = NULL;
	struct ifaddrs *ifa = NULL;
	
	if (getifaddrs(&interfaces) == -1) {
		perror("getifaddrs");
		return;
	}
	
	for (ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
		if (!ifa->ifa_addr) continue;
		
		sa_family_t family = ifa->ifa_addr->sa_family;
		
		// Skip interfaces that are not UP or are LOOPBACK
		if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) {
			continue;
		}
		
		char addrBuf[INET_ADDRSTRLEN] = {0};
		
		if (family == AF_INET) {
			struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
			inet_ntop(AF_INET, &addr->sin_addr, addrBuf, sizeof(addrBuf));
			
			NSString *infName = @(ifa->ifa_name);
			if ([infName hasPrefix:@"en"] || [infName hasPrefix:@"bridge"]) {
				[self.localIpAddresses addObject:[NSString stringWithCString:addrBuf]];
			}
			
			NSLog(@"%s (IPv4): %s", ifa->ifa_name, addrBuf);
		}
	}
	
	freeifaddrs(interfaces);
}

-(void)selectLocalIpAddress: (NSString *)value {
	if (_selectedLocalIpAddress == value) {
		return;
	}
	_selectedLocalIpAddress = value;
	[[TPPreferencesManager sharedPreferencesManager] setValue:value forKey:LOCAL_IP_KEY];
	[self _networkChanged];
}

@end

static void _networkChangeCallBack(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info)
{
	@autoreleasepool {
		TPNetworkConfigurationWatcher * self = (__bridge TPNetworkConfigurationWatcher*)info;
		
		for (CFIndex i = 0; i < CFArrayGetCount(changedKeys); i++) {
			CFStringRef key = CFArrayGetValueAtIndex(changedKeys, i);
			NSString *keyStr = (__bridge NSString*)key;
			if ([keyStr hasPrefix:@"State:/Network/Interface/"] && [keyStr hasSuffix:@"IPv4"]) {
				[self updateLocalIpAddresses];
				break;
			}
		}
		
		BOOL isControlledAsServer = [[TPServerController defaultController] isControlled];
		NSString *serverInterfaceName = [[[TPServerController defaultController] currentConnection] networkInterfaceName];
		
		BOOL isControllingAsClient = [[TPClientController defaultController] isControlling];
		NSString *clientInterfaceName = [[[TPClientController defaultController] currentConnection] networkInterfaceName];
		
		DebugLog(@"Network changed: server(%@, %d); client(%@, %d)", serverInterfaceName, isControlledAsServer, clientInterfaceName, isControllingAsClient);

		serverInterfaceName = isControlledAsServer ? serverInterfaceName : nil;
		clientInterfaceName = isControllingAsClient ? clientInterfaceName : nil;
		
		// Connections in use
		if (serverInterfaceName || clientInterfaceName) {
			for (CFIndex i = 0; i < CFArrayGetCount(changedKeys); i++) {
				CFStringRef key = CFArrayGetValueAtIndex(changedKeys, i);
				CFPropertyListRef value = SCDynamicStoreCopyValue(store, key);

				DebugLog(@"Changed key: %@, value: %@", key, value);

				if (value) {
					CFRelease(value);
				} else {
					// No value for this inf, should be disconnected.
					NSString *keyStr = (__bridge NSString*)key;
					if ((serverInterfaceName && [keyStr hasPrefix:[NSString stringWithFormat:@"State:/Network/Interface/%@", serverInterfaceName]]) ||
						(clientInterfaceName && [keyStr hasPrefix:[NSString stringWithFormat:@"State:/Network/Interface/%@", clientInterfaceName]]) ) {
						// Only notify changes when the corresponding network interface is down.
						[self _networkChanged];
						return;
					}
				}
				
			}
		} else {
			[self _networkChanged];
		}
	}
}


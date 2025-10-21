//
//  TPBonjourController.m
//  teleport
//
//  Created by JuL on 30/01/05.
//  Copyright 2003-2005 abyssoft. All rights reserved.
//

#import "TPBonjourController.h"

#import "TPHostsManager.h"
#import "TPNetworkConnection.h"
#import "TPPreferencesManager.h"
#import "TPMainController.h"

#import "TPLocalHost.h"
#import "TPRemoteHost.h"

#import <sys/socket.h>
#import <arpa/inet.h>
#import <sys/types.h>
#import <netinet/in.h>
#import <netdb.h>
#import "TPNetworkConfigurationWatcher.h"

#define SHOW_LOCALHOST DEBUG_BUILD
#define RESOLVE_TIMEOUT 10.0
#define PING_MAX_COUNT "30"

#define TXT_VERSION 1

static NSString * TPRecordTXTVersionKey = @"txtvers";
static NSString * TPRecordIDKey = @"id";
static NSString * TPRecordNameKey = @"name";
static NSString * TPRecordProtocolVersionKey = @"protocol";
static NSString * TPRecordScreenSizesKey = @"screen-sizes";
static NSString * TPRecordCapabilitiesKey = @"capabilities";
static NSString * TPRecordOSVersionKey = @"os-vers";
static NSString * TPRecordSelectedServiceIpAddressKey = @"service-ip";
static NSString * TPRecordHideIfNotPaired = @"hide";

static TPBonjourController * _defaultBonjourController = nil;

@interface IpPort : NSObject

@property NSString *ipAddress;
@property int port;

@end

@implementation IpPort

@end

static void pingRemoteAsync(NSString *host) {
	static NSMutableDictionary<NSString *, NSTask *> *tasks;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		tasks = [[NSMutableDictionary alloc] init];
	});

	DebugLog(@"ping -c "PING_MAX_COUNT" %@", host);
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/sbin/ping";
	task.arguments = @[@"-c", @PING_MAX_COUNT, host];
	
	NSPipe *pipe = [NSPipe pipe];
	task.standardOutput = pipe;
	task.standardError = pipe;
	
	NSFileHandle *outputHandle = pipe.fileHandleForReading;
	
	task.terminationHandler = ^(NSTask *finishedTask) {
	};
	
	outputHandle.readabilityHandler = ^(NSFileHandle *handle) {
		NSData *data = [handle availableData];
		if (data.length == 0) {
			outputHandle.readabilityHandler = nil;
			return;
		}
		
		NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
		for (NSString *line in lines) {
			if (line.length > 0) {
				NSLog(@"%@", line);
				if ([line containsString:@"bytes from"]) {
					NSLog(@"ping successfully to %@.", host);
					[task terminate];
					return;
				}
				if ([line containsString:@"Request timeout for icmp_seq "PING_MAX_COUNT]) {
					DebugLog(@"ping to %@ - Timeout. Reset connections.", host);
					dispatch_async(dispatch_get_main_queue(), ^{
						[[TPMainController sharedController] resetAllConnections];
					});
				}
			}
		}
	};
	
	[task launch];
	DebugLog(@"ping to %@ - start.", host);
	
	NSTask *prevTask = [tasks objectForKey:host];
	[prevTask terminate];

	[tasks setValue:task forKey:host];
}

@implementation TPBonjourController

+ (TPBonjourController*)defaultController
{
	if(_defaultBonjourController == nil)
		_defaultBonjourController = [[TPBonjourController alloc] init];
	
	return _defaultBonjourController;
}

+ (NSDictionary*)dictionaryFromProtocolSpecificInformation:(NSString*)info
{
	NSMutableDictionary * dictionary = [[NSMutableDictionary alloc] init];
	NSArray * pairs = [info componentsSeparatedByString:@"\x01"];
	NSEnumerator * pairEnum = [pairs objectEnumerator];
	NSString * pair;
	
	while((pair = [pairEnum nextObject]) != nil) {
		NSArray * keyAndValue = [pair componentsSeparatedByString:@"="];
		if([keyAndValue count] == 2) {
			dictionary[keyAndValue[0]] = keyAndValue[1];
		}
	}
	
	return dictionary;
}

+ (NSString*)protocolSpecificInformationFromDictionary:(NSDictionary*)dictionary
{
	NSMutableString * info = [[NSMutableString alloc] init];
	NSEnumerator * keyEnum = [dictionary keyEnumerator];
	NSString * key;
	
	while((key = [keyEnum nextObject]) != nil) {
		NSString * value = dictionary[key];
		[info appendFormat:@"%@=%@\x01", key, value];
	}

	[info replaceCharactersInRange:NSMakeRange([info length]-1, 1) withString:@""]; // remove last \n
	
	return info;
}

- (instancetype) init
{
	self = [super init];

	_publishService = nil;
	_browseService = nil;
	_browsers = [[NSMutableDictionary alloc] init];
	_services = [[NSMutableSet alloc] init];
	
	_namesToIdentifiersDict = [[NSMutableDictionary alloc] init];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateTXTRecordOfPublishService) name:TPHostDidUpdateNotification object:[TPLocalHost localHost]];
	
	return self;
}


#pragma mark -
#pragma mark Publisher

- (void)publishWithPort:(int)port
{
	if(_publishService != nil)
		return;
	
	TPLocalHost * localHost = [TPLocalHost localHost];
	
	_publishService = [[NSNetService alloc] initWithDomain:@"" type:RV_SERVICE name:[localHost bonjourName] port:port];
	
	if(_publishService != nil) {
		[self updateTXTRecordOfPublishService];
		[_publishService setDelegate:self];
		[_publishService publish];
	}
	else
		DebugLog(@"Error publishing Bonjour service");
}

- (void)updateTXTRecordOfPublishService
{
	/* First check if _publishService even exists */
	// (This method can be called by a notification, even before _publishService has been initialized
	// Adding this code prevents the "Can't set TXT record data" from appearing upon opening)
	if(_publishService == nil)
		return;
	
	NSArray * screens = [[TPLocalHost localHost] screens];
	
	NSString *selectedIpAddress = [[TPMainController sharedController] networkConfigurationWatcher].selectedLocalIpAddress;
	if (!selectedIpAddress || [selectedIpAddress isEqualToString:@"0.0.0.0"] || [selectedIpAddress isEqualToString:@"127.0.0.1"]) {
		selectedIpAddress = @"";
	}

	NSDictionary * recordDict = @{TPRecordTXTVersionKey: [NSString stringWithInt:TXT_VERSION],
								 TPRecordIDKey: [[TPLocalHost localHost] identifier],
								 TPRecordNameKey: [[TPLocalHost localHost] computerName],
								 TPRecordProtocolVersionKey: [NSString stringWithInt:PROTOCOL_VERSION],
								 TPRecordScreenSizesKey: [TPScreen stringFromScreens:screens],
								  TPRecordCapabilitiesKey: [NSString stringWithInt:[[TPLocalHost localHost] capabilities]],
								  TPRecordOSVersionKey: [NSString stringWithInt:[[TPLocalHost localHost] osVersion]],
								  TPRecordSelectedServiceIpAddressKey: selectedIpAddress,
								  TPRecordHideIfNotPaired: ([[TPPreferencesManager sharedPreferencesManager] intForPref:TRUST_REQUEST_BEHAVIOR] == TRUST_REQUEST_REJECT) ? @"1" : @"0"};
	
	NSData * recordData = [NSNetService dataFromTXTRecordDictionary:recordDict];
	if(![_publishService setTXTRecordData:recordData])
		NSLog(@"Can't set TXT record data");
}

- (void)unpublish
{
	if(_publishService != nil) {
		[_publishService stop];
		_publishService = nil;
	}
}

- (void)netServiceWillPublish:(NSNetService *)service
{
	DebugLog(@"netServiceWillPublish: %@", service);
}

- (void)netServiceWillResolve:(NSNetService *)service {
	DebugLog(@"netServiceWillResolve: %@", service);
}

- (void)netService:(NSNetService *)service didNotPublish:(NSDictionary *)errorDict
{
	DebugLog(@"netServiceDidNotPublish: %@, %@", service, errorDict);
}

- (void)retryResolve:(NSNetService *)service {
	if (service.port == -1) {
		for (NSNetService *_service in _services) {
			if (_service.hostName == service.hostName) {
				if([service respondsToSelector:@selector(resolveWithTimeout:)])
					[service resolveWithTimeout:RESOLVE_TIMEOUT];
				else
					[service resolve];
				return;
			}
		}
	}
}

- (void)netServiceDidStop:(NSNetService *)service
{
	DebugLog(@"netServiceDidStop: %@", service);
	[self retryResolve:service];
}


#pragma mark -
#pragma mark Browser

- (void)browse
{
	if(_browseService == nil) {
		_browseService = [[NSNetServiceBrowser alloc] init];
		[_browseService scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[_browseService setDelegate:self];
	}
	
	[_browseService searchForBrowsableDomains];
}

- (void)stopBrowsing
{
	[_browseService stop];
	for (NSNetServiceBrowser *_browser in [_browsers allValues]) {
		[_browser stop];
	}
	[_browsers removeAllObjects];
	for (NSNetService *_service in _services) {
		[_service stop];
	}
	[_services removeAllObjects];
}

- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser *)browser
{
	//DebugLog(@"willSearch");
	DebugLog(@"netServiceBrowserWillSearch: %@", browser);
}

- (void)netServiceBrowserDidStopSearch:(NSNetServiceBrowser *)browser
{
	DebugLog(@"netServiceBrowserDidStopSearch: %@", browser);

}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict
{
	//DebugLog(@"didNotSearch");
	DebugLog(@"didNotSearch: %@", errorDict);
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didFindDomain:(NSString *)domainString moreComing:(BOOL)moreComing
{
	NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
	browser.delegate = self;
	[browser scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	[browser searchForServicesOfType:RV_SERVICE inDomain:domainString];
	
	[_browsers setObject:browser forKey:domainString];
	
	DebugLog(@"didFindDomain: %@", domainString);
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didRemoveDomain:(NSString *)domainString moreComing:(BOOL)moreComing
{
	PRINT_ME
	NSNetServiceBrowser *browser = [_browsers objectForKey:domainString];
	
	if (browser != nil) {
		[browser stop];
		[_browsers removeObjectForKey:domainString];
	}
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing
{
	[_services addObject:service];
	
	[service setDelegate:self];
	
	DebugLog(@"did find service: %@", service);

	if([service respondsToSelector:@selector(resolveWithTimeout:)])
		[service resolveWithTimeout:RESOLVE_TIMEOUT];
	else
		[service resolve];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing
{
	PRINT_ME
	NSString * identifier = _namesToIdentifiersDict[[service name]];
	TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:identifier];
	
	if(remoteHost != nil)
		[[TPHostsManager defaultManager] removeBonjourHost:remoteHost];

	[_namesToIdentifiersDict removeObjectForKey:[service name]];
	[_services removeObject:service];
}

- (BOOL)_updateHost:(TPRemoteHost*)host withRecordDict:(NSDictionary*)recordDict
{
	TPHostCapability capabilities = [recordDict[TPRecordCapabilitiesKey] intValue];
	[host setCapabilities:capabilities];
	
	SInt32 osVersion = [recordDict[TPRecordOSVersionKey] intValue];
	[host setOSVersion:osVersion];
	
	NSArray * screens = [TPScreen screensFromString:[recordDict[TPRecordScreenSizesKey] stringValue]];
	[host setScreens:screens];

	NSString * computerName = [recordDict[TPRecordNameKey] stringValue];
	[host setComputerName:computerName];
	
	return ([screens count] > 0) && (computerName != nil);
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
	NSDictionary * recordDict = nil;
	
	DebugLog(@"did resolve service: %@", service);

	NSData * recordData = [service TXTRecordData];
	if(recordData != nil) {
		recordDict = [NSNetService dictionaryFromTXTRecordData:recordData];
	}
	
	if(recordDict == nil) {
		NSLog(@"Invalid host: no TXT record!");
		[service stop];
		return;
	}
	
	if([recordDict[TPRecordTXTVersionKey] intValue] != TXT_VERSION) {
		DebugLog(@"Invalid host: out of date TXT record: %d", [recordDict[TPRecordTXTVersionKey] intValue]);
		[service stop];
		return;
	}
	
	if([recordDict[TPRecordProtocolVersionKey] intValue] == PROTOCOL_VERSION) {
		NSString *identifier = [recordDict[TPRecordIDKey] stringValue];
		NSString *selectedServiceIpAddress = [recordDict[TPRecordSelectedServiceIpAddressKey] stringValue];
		IpPort *ipPort = [self resolveIpPort:service withSelected:selectedServiceIpAddress];

		DebugLog(@"netServiceDidResolveAddress: Id=%@, resolved addr:%@:%d", identifier, ipPort.ipAddress, ipPort.port);
		if (!ipPort) {
			return;
		}
		
		TPRemoteHost * remoteHost = [[TPRemoteHost alloc] initWithIdentifier:identifier address:ipPort.ipAddress port:ipPort.port];
		DebugLog(@"remoteHost: %@", remoteHost);

		if([self _updateHost:remoteHost withRecordDict:recordDict]) {
			[remoteHost setHostState:TPHostSharedState];
			
			if([service respondsToSelector:@selector(startMonitoring)])
				[service startMonitoring];
			
			DebugLog(@"_namesToIdentifiersDict: %@", _namesToIdentifiersDict);
			DebugLog(@"[remoteHost identifier]: %@, [service name]: %@", [remoteHost identifier], [service name]);

			
			_namesToIdentifiersDict[[service name]] = [remoteHost identifier];
			
			if(![remoteHost isEqual:[TPLocalHost localHost]]) {
				[[TPHostsManager defaultManager] addBonjourHost:remoteHost];
				pingRemoteAsync(ipPort.ipAddress);
			}
			else {
#if SHOW_LOCALHOST	
				[[TPHostsManager defaultManager] addBonjourHost:remoteHost];
#endif
			}
		}
		
	}
	else {
		TPRemoteHost * remoteHost = [[TPRemoteHost alloc] initWithIdentifier:[recordDict[TPRecordIDKey] stringValue] address:nil port:0];
		DebugLog(@"incompatible: %d != %d", [recordDict[TPRecordProtocolVersionKey] intValue], PROTOCOL_VERSION);

		if([self _updateHost:remoteHost withRecordDict:recordDict]) {
			[remoteHost setHostState:TPHostIncompatibleState];
			
			_namesToIdentifiersDict[[service name]] = [remoteHost identifier];
			
			if(![remoteHost isEqual:[TPLocalHost localHost]] && ([remoteHost identifier] != nil))
				[[TPHostsManager defaultManager] addBonjourHost:remoteHost];
		}
		
	}
	
//	[service stop];
//	[service release];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict
{
	DebugLog(@"netServiceDidNotResolve: service: %@, reason: %@", service, errorDict);
	[self retryResolve:service];
}

- (void)netService:(NSNetService *)sender didUpdateTXTRecordData:(NSData *)data
{
	if(data == nil)
		return;
	
	NSString * previousIdentifier = _namesToIdentifiersDict[[sender name]];
	NSDictionary * recordDict = [NSNetService dictionaryFromTXTRecordData:data];
	NSString * identifier = [recordDict[TPRecordIDKey] stringValue];
	
	if([identifier isEqualToString:previousIdentifier]) {
		TPRemoteHost * host = [[TPHostsManager defaultManager] hostWithIdentifier:identifier];
		DebugLog(@"netService: sameId=%@, host=%@", identifier, host);
		if(host != nil) {
			[self _updateHost:host withRecordDict:recordDict];
		}
	}
	else {
		TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:previousIdentifier];
		NSString * selectedIpAddress = [recordDict[TPRecordSelectedServiceIpAddressKey] stringValue];
		IpPort *ipPort = [self resolveIpPort:sender withSelected:selectedIpAddress];
		
		DebugLog(@"netService: newId=%@, prevId=%@, resolved addr:%@:%d", identifier, previousIdentifier, ipPort.ipAddress, ipPort.port);
		
		if (!ipPort) {
			return;
		}

		if(remoteHost != nil) {
			TPRemoteHost * newRemoteHost = [[TPRemoteHost alloc] initWithIdentifier:identifier address:ipPort.ipAddress port:ipPort.port];
			
			if([self _updateHost:newRemoteHost withRecordDict:recordDict]) {
				[[TPHostsManager defaultManager] removeBonjourHost:remoteHost];
				
				[[TPHostsManager defaultManager] addBonjourHost:newRemoteHost];
				_namesToIdentifiersDict[[sender name]] = identifier;
			}

		}
	}
}

-(IpPort *)resolveIpPort: (NSNetService *)service withSelected: (NSString *)selectedIpAddress {
	NSArray * addresses = [service addresses];
	if([addresses count] == 0)
		return nil;
	
	NSMutableArray *ipPorts = [[NSMutableArray alloc] init];
	
	// Iterate through addresses until we find an IPv4 address
	int index;
	for(index = 0; index < [addresses count]; index++) {
		NSData * address = addresses[index];
		struct sockaddr * socketAddress = (struct sockaddr *)[address bytes];
		
		if(socketAddress->sa_family == AF_INET) {
			if(socketAddress != nil) {
				char buffer[256];
				if(inet_ntop(AF_INET, &((struct sockaddr_in *)socketAddress)->sin_addr, buffer, sizeof(buffer))) {

					NSString *ipAddressString = @(buffer);
					int port = ntohs(((struct sockaddr_in *)socketAddress)->sin_port);
					
					IpPort *ipPort = [[IpPort alloc] init];
					ipPort.ipAddress = ipAddressString;
					ipPort.port = port;
					
					[ipPorts addObject:ipPort];
				}
			}
		}
	}
	
	IpPort *selectedIpPort = nil;
	for (IpPort *ipPort in ipPorts) {
		if (selectedIpAddress.length > 0) {
			if ([ipPort.ipAddress isEqualToString:selectedIpAddress]) {
				selectedIpPort = ipPort;
				break;
			}
		} else {
			// prefer 169.xxx.xxx.xxx
			if (selectedIpPort && [ipPort.ipAddress hasPrefix:@"169."]) {
				selectedIpPort = ipPort;
			} else {
				selectedIpPort = ipPort;
			}
		}
	}
	
	return selectedIpPort;
}

@end

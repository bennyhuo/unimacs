//
//  TPScreenLockWatcher.m
//  teleport
//
//  Created by benny on 2025/6/24.
//

#import "TPScreenLockWatcher.h"
#import "common.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/IOKitLib.h>
#import "TPMainController.h"

#define KEY_SCREEN_LOCKED @"com.apple.screenIsLocked"
#define KEY_SCREEN_UNLOCKED @"com.apple.screenIsUnlocked"

static TPScreenLockWatcher *defaultWatcher;

static BOOL isScreenLocked(void) {
	CFDictionaryRef sessionInfo = CGSessionCopyCurrentDictionary();
	if (!sessionInfo) return NO;

	CFBooleanRef locked = CFDictionaryGetValue(sessionInfo, CFSTR("CGSSessionScreenIsLocked"));
	BOOL result = (locked == kCFBooleanTrue);
	CFRelease(sessionInfo);
	return result;
}

@interface TPScreenLockWatcher()
@property (readonly) BOOL isLocked;
@property (strong) id lockObserver;
@property (strong) id unlockObserver;
@end

@implementation TPScreenLockWatcher
{
	io_connect_t rootPowerDomainRef;       // a reference to the Root Power Domain IOService
	io_object_t notifierObject;   // notifier object, used to deregister later
	IONotificationPortRef notifyPortRef; // notification port allocated by IORegisterForSystemPower
}

- (instancetype)init
{
	self = [super init];
	if (self) {
		self.lockObserver = [[NSDistributedNotificationCenter defaultCenter] addObserverForName:KEY_SCREEN_LOCKED
																	 object:nil
																	  queue:[NSOperationQueue mainQueue]
																 usingBlock:^(NSNotification * _Nonnull note) {
			DebugLog(@"Screen locked");
			self->_isLocked = YES;
		}];

		self.unlockObserver = [[NSDistributedNotificationCenter defaultCenter] addObserverForName:KEY_SCREEN_UNLOCKED
																	 object:nil
																	  queue:[NSOperationQueue mainQueue]
																 usingBlock:^(NSNotification * _Nonnull note) {
			DebugLog(@"Screen unlocked");
			self->_isLocked = NO;
			[[TPMainController sharedController] resetAllConnectionsIfNotInControl];
		}];
		
		_isLocked = isScreenLocked();
		
		DebugLog(@"Screen isLocked=%@ from init.", @(_isLocked));
		
		// Get a reference to the Root Power Domain
		rootPowerDomainRef = IORegisterForSystemPower((__bridge void *)(self), &notifyPortRef, powerStatusCallback, &notifierObject);
		if (rootPowerDomainRef == IO_OBJECT_NULL) {
			NSLog(@"IORegisterForSystemPower failed");
		} else {
			CFRunLoopAddSource(CFRunLoopGetCurrent(),
							   IONotificationPortGetRunLoopSource(notifyPortRef),
							   kCFRunLoopDefaultMode);
		}
	}
	return self;
}

- (void)dealloc
{
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self.lockObserver];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self.unlockObserver];
	
	if (rootPowerDomainRef != IO_OBJECT_NULL) {
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notifyPortRef), kCFRunLoopDefaultMode);
		IONotificationPortDestroy(notifyPortRef);
		notifyPortRef = NULL;
		
		IODeregisterForSystemPower(&notifierObject);
		notifierObject = IO_OBJECT_NULL;
		
		IOServiceClose(rootPowerDomainRef);
		rootPowerDomainRef = IO_OBJECT_NULL;
	}
}

+(BOOL) isLocked {
	if (defaultWatcher == nil) {
		defaultWatcher = [[TPScreenLockWatcher alloc] init];
	}
	return defaultWatcher.isLocked;
}

+(void) setup {
	if (defaultWatcher == nil) {
		defaultWatcher = [[TPScreenLockWatcher alloc] init];
	}
}

static void powerStatusCallback(void *refCon, io_service_t service,
						  natural_t messageType, void *messageArgument) {
	TPScreenLockWatcher *self = (__bridge TPScreenLockWatcher*)refCon;
	switch (messageType) {
		case kIOMessageSystemWillSleep:
			NSLog(@"System will sleep");
			// Allow system sleep
			IOAllowPowerChange(self->rootPowerDomainRef, (long)messageArgument);
			break;

		case kIOMessageCanSystemSleep:
			NSLog(@"System can sleep");
			IOAllowPowerChange(self->rootPowerDomainRef, (long)messageArgument);
			break;

		case kIOMessageSystemHasPoweredOn:
			NSLog(@"System woke up");
			[[TPMainController sharedController] resetAllConnectionsIfNotInControl];
			break;
		default:
			break;
	}
}

@end

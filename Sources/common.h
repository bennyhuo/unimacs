/*
 *  common.h
 *  Teleport
 *
 *  Created by JuL on Thu Dec 04 2003.
 *  Copyright (c) 2003-2005 abyssoft. All rights reserved.
 *
 */

#include <pthread.h>

// Forward declaration for TPPreferencesManager (defined in Swift)
@class TPPreferencesManager;

/* Debug */
#define DEBUG_GENERAL 0

// Helper macro to extract just the filename from __FILE__
#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

// Thread label helper
#define __THREAD_LABEL__ ([NSThread isMainThread] ? @"MAIN " : [NSString stringWithFormat:@"T-%-5u", pthread_mach_thread_np(pthread_self())])

// MARK: - Preference Keys (defined in Constants.h, kept here for ObjC compatibility)

// Key tags
#define COMMAND_KEY_TAG 20
#define ALT_KEY_TAG 19
#define CTRL_KEY_TAG 18
#define SHIFT_KEY_TAG 17
#define CAPSLOCK_KEY_TAG 16

// Log Module Keys (must match Swift LogModule.settingsKey)
#define LOG_MODULE_GENERAL_KEY @"logModule_0_enabled"
#define LOG_MODULE_NETWORK_KEY @"logModule_1_enabled"
#define LOG_MODULE_TRANSFER_KEY @"logModule_2_enabled"
#define LOG_MODULE_CLIPBOARD_KEY @"logModule_3_enabled"
#define LOG_MODULE_CONTROL_KEY @"logModule_4_enabled"
#define LOG_MODULE_SECURITY_KEY @"logModule_5_enabled"

// Debug log key (for backward compatibility with existing code)
#define ENABLE_DEBUG_LOG @"enableLogging"

// Module enabled check (defaults to YES if not set)
#define IS_MODULE_ENABLED(moduleKey) \
    ([[TPPreferencesManager sharedPreferencesManager] valueForPref:moduleKey] == nil ? YES : \
     [[TPPreferencesManager sharedPreferencesManager] boolForPref:moduleKey])

// Unified debug log format (matches Swift debugLog format)
// Debug build: [filename:line] [thread] [function] level » message
// Release build: [thread] level » message (hide code location info)

#ifdef DEBUG
    #define DebugLogModule(moduleKey, logString, args...) \
    do { \
        if([[TPPreferencesManager sharedPreferencesManager] boolForPref:ENABLE_DEBUG_LOG] && IS_MODULE_ENABLED(moduleKey)) { \
            NSLog(@"[%s:%d] [%@] [%s] 🔍 " logString, __FILENAME__, __LINE__, __THREAD_LABEL__, __PRETTY_FUNCTION__, ##args); \
        } \
    } while(0)

    #define ErrorLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%s:%d] [%@] [%s] ❌ " logString, __FILENAME__, __LINE__, __THREAD_LABEL__, __PRETTY_FUNCTION__, ##args); \
    } while(0)

    #define WarningLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%s:%d] [%@] [%s] ⚠️ " logString, __FILENAME__, __LINE__, __THREAD_LABEL__, __PRETTY_FUNCTION__, ##args); \
    } while(0)

    #define InfoLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%s:%d] [%@] [%s] ℹ️ " logString, __FILENAME__, __LINE__, __THREAD_LABEL__, __PRETTY_FUNCTION__, ##args); \
    } while(0)
#else
    // Release build: hide file, line, and function info
    #define DebugLogModule(moduleKey, logString, args...) \
    do { \
        if([[TPPreferencesManager sharedPreferencesManager] boolForPref:ENABLE_DEBUG_LOG] && IS_MODULE_ENABLED(moduleKey)) { \
            NSLog(@"[%@] 🔍 " logString, __THREAD_LABEL__, ##args); \
        } \
    } while(0)

    #define ErrorLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%@] ❌ " logString, __THREAD_LABEL__, ##args); \
    } while(0)

    #define WarningLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%@] ⚠️ " logString, __THREAD_LABEL__, ##args); \
    } while(0)

    #define InfoLogModule(moduleKey, logString, args...) \
    do { \
        NSLog(@"[%@] ℹ️ " logString, __THREAD_LABEL__, ##args); \
    } while(0)
#endif

// Default module macros (use General module)
#define DebugLog(logString, args...) DebugLogModule(LOG_MODULE_GENERAL_KEY, logString, ##args)
#define ErrorLog(logString, args...) ErrorLogModule(LOG_MODULE_GENERAL_KEY, logString, ##args)
#define WarningLog(logString, args...) WarningLogModule(LOG_MODULE_GENERAL_KEY, logString, ##args)
#define InfoLog(logString, args...) InfoLogModule(LOG_MODULE_GENERAL_KEY, logString, ##args)

// Module-specific convenience macros
#define NetworkDebugLog(logString, args...) DebugLogModule(LOG_MODULE_NETWORK_KEY, logString, ##args)
#define NetworkErrorLog(logString, args...) ErrorLogModule(LOG_MODULE_NETWORK_KEY, logString, ##args)
#define NetworkWarningLog(logString, args...) WarningLogModule(LOG_MODULE_NETWORK_KEY, logString, ##args)
#define NetworkInfoLog(logString, args...) InfoLogModule(LOG_MODULE_NETWORK_KEY, logString, ##args)

#define TransferDebugLog(logString, args...) DebugLogModule(LOG_MODULE_TRANSFER_KEY, logString, ##args)
#define TransferErrorLog(logString, args...) ErrorLogModule(LOG_MODULE_TRANSFER_KEY, logString, ##args)

#define SecurityDebugLog(logString, args...) DebugLogModule(LOG_MODULE_SECURITY_KEY, logString, ##args)
#define SecurityErrorLog(logString, args...) ErrorLogModule(LOG_MODULE_SECURITY_KEY, logString, ##args)

#define ControlDebugLog(logString, args...) DebugLogModule(LOG_MODULE_CONTROL_KEY, logString, ##args)

/* Macros */
#define DELETE(obj) if(obj) {[obj release]; obj=nil;}
#define PRINT_ME DebugLog(@"%@: %s", self, __PRETTY_FUNCTION__);
#define PRINT_ME_IF(cond) do{if(cond) DebugLog(@"%@: %s", self, __PRETTY_FUNCTION__);}while(0)

/* Constants */
#define RV_SERVICE @"_teleport._tcp"

#define LEFT_MOUSE_BUTTON 0
#define RIGHT_MOUSE_BUTTON 1
#define OTHER_MOUSE_BUTTON 2

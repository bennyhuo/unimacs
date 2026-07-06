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

// Numeric module ids (must match Swift LogModule rawValue)
#define LOG_MOD_GENERAL   0
#define LOG_MOD_NETWORK   1
#define LOG_MOD_TRANSFER  2
#define LOG_MOD_CLIPBOARD 3
#define LOG_MOD_CONTROL   4
#define LOG_MOD_SECURITY  5

// Numeric levels (must match Swift LogLevel rawValue)
#define LOG_LVL_DEBUG   0
#define LOG_LVL_INFO    1
#define LOG_LVL_WARNING 2
#define LOG_LVL_ERROR   3

// Bridge into the Swift rotating file logger (implemented via @_cdecl in
// TPFileLogger.swift). Writes the formatted message to the local log file.
extern void TPFileLog(int level, int module, const char *message);

// Unified logging core.
// - The full message is always written to the local rotating log file.
// - The console (NSLog) only receives "key" logs: warnings and errors
//   (consoleAlways == YES), plus everything when debug logging is enabled.
//
// Debug build:   [filename:line] [thread] [function] <prefix> message
// Release build: [thread] <prefix> message  (hide code location info)

#ifdef DEBUG
    #define _TPLogModule(levelInt, moduleKey, moduleInt, prefix, consoleAlways, logString, args...) \
    do { \
        if(IS_MODULE_ENABLED(moduleKey)) { \
            NSString *__tpLogMsg = [NSString stringWithFormat:(@"[%s:%d] [%@] [%s] " prefix " " logString), __FILENAME__, __LINE__, __THREAD_LABEL__, __PRETTY_FUNCTION__, ##args]; \
            TPFileLog((levelInt), (moduleInt), [__tpLogMsg UTF8String]); \
            if((consoleAlways) || [[TPPreferencesManager sharedPreferencesManager] boolForPref:ENABLE_DEBUG_LOG]) { \
                NSLog(@"%@", __tpLogMsg); \
            } \
        } \
    } while(0)
#else
    // Release build: hide file, line, and function info
    #define _TPLogModule(levelInt, moduleKey, moduleInt, prefix, consoleAlways, logString, args...) \
    do { \
        if(IS_MODULE_ENABLED(moduleKey)) { \
            NSString *__tpLogMsg = [NSString stringWithFormat:(@"[%@] " prefix " " logString), __THREAD_LABEL__, ##args]; \
            TPFileLog((levelInt), (moduleInt), [__tpLogMsg UTF8String]); \
            if((consoleAlways) || [[TPPreferencesManager sharedPreferencesManager] boolForPref:ENABLE_DEBUG_LOG]) { \
                NSLog(@"%@", __tpLogMsg); \
            } \
        } \
    } while(0)
#endif

// Generic module macros (level chosen by caller via the level-specific wrappers below)
#define DebugLogModule(moduleKey, logString, args...)   _TPLogModule(LOG_LVL_DEBUG,   moduleKey, LOG_MOD_GENERAL, @"🔍", NO,  logString, ##args)
#define InfoLogModule(moduleKey, logString, args...)    _TPLogModule(LOG_LVL_INFO,    moduleKey, LOG_MOD_GENERAL, @"ℹ️", NO,  logString, ##args)
#define WarningLogModule(moduleKey, logString, args...) _TPLogModule(LOG_LVL_WARNING, moduleKey, LOG_MOD_GENERAL, @"⚠️", YES, logString, ##args)
#define ErrorLogModule(moduleKey, logString, args...)   _TPLogModule(LOG_LVL_ERROR,   moduleKey, LOG_MOD_GENERAL, @"❌", YES, logString, ##args)

// Default module macros (use General module)
#define DebugLog(logString, args...)   _TPLogModule(LOG_LVL_DEBUG,   LOG_MODULE_GENERAL_KEY, LOG_MOD_GENERAL, @"🔍", NO,  logString, ##args)
#define InfoLog(logString, args...)    _TPLogModule(LOG_LVL_INFO,    LOG_MODULE_GENERAL_KEY, LOG_MOD_GENERAL, @"ℹ️", NO,  logString, ##args)
#define WarningLog(logString, args...) _TPLogModule(LOG_LVL_WARNING, LOG_MODULE_GENERAL_KEY, LOG_MOD_GENERAL, @"⚠️", YES, logString, ##args)
#define ErrorLog(logString, args...)   _TPLogModule(LOG_LVL_ERROR,   LOG_MODULE_GENERAL_KEY, LOG_MOD_GENERAL, @"❌", YES, logString, ##args)

// Module-specific convenience macros
#define NetworkDebugLog(logString, args...)   _TPLogModule(LOG_LVL_DEBUG,   LOG_MODULE_NETWORK_KEY, LOG_MOD_NETWORK, @"🔍", NO,  logString, ##args)
#define NetworkErrorLog(logString, args...)   _TPLogModule(LOG_LVL_ERROR,   LOG_MODULE_NETWORK_KEY, LOG_MOD_NETWORK, @"❌", YES, logString, ##args)
#define NetworkWarningLog(logString, args...) _TPLogModule(LOG_LVL_WARNING, LOG_MODULE_NETWORK_KEY, LOG_MOD_NETWORK, @"⚠️", YES, logString, ##args)
#define NetworkInfoLog(logString, args...)    _TPLogModule(LOG_LVL_INFO,    LOG_MODULE_NETWORK_KEY, LOG_MOD_NETWORK, @"ℹ️", NO,  logString, ##args)

#define TransferDebugLog(logString, args...) _TPLogModule(LOG_LVL_DEBUG, LOG_MODULE_TRANSFER_KEY, LOG_MOD_TRANSFER, @"🔍", NO,  logString, ##args)
#define TransferErrorLog(logString, args...) _TPLogModule(LOG_LVL_ERROR, LOG_MODULE_TRANSFER_KEY, LOG_MOD_TRANSFER, @"❌", YES, logString, ##args)

#define SecurityDebugLog(logString, args...) _TPLogModule(LOG_LVL_DEBUG, LOG_MODULE_SECURITY_KEY, LOG_MOD_SECURITY, @"🔍", NO,  logString, ##args)
#define SecurityErrorLog(logString, args...) _TPLogModule(LOG_LVL_ERROR, LOG_MODULE_SECURITY_KEY, LOG_MOD_SECURITY, @"❌", YES, logString, ##args)

#define ControlDebugLog(logString, args...)  _TPLogModule(LOG_LVL_DEBUG, LOG_MODULE_CONTROL_KEY, LOG_MOD_CONTROL, @"🔍", NO,  logString, ##args)

/* Macros */
#define DELETE(obj) if(obj) {[obj release]; obj=nil;}
#define PRINT_ME DebugLog(@"%@: %s", self, __PRETTY_FUNCTION__);
#define PRINT_ME_IF(cond) do{if(cond) DebugLog(@"%@: %s", self, __PRETTY_FUNCTION__);}while(0)

/* Constants */
#define RV_SERVICE @"_teleport._tcp"

#define LEFT_MOUSE_BUTTON 0
#define RIGHT_MOUSE_BUTTON 1
#define OTHER_MOUSE_BUTTON 2

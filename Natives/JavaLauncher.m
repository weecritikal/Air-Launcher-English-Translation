#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include "utils.h"
#include "ZinkConfig.h"

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

/// JIT26CreateRegionLegacy() is a bare `brk #0x69`. It is a message to an attached JIT
/// debugger script, which is expected to trap it, do the work and resume us. When no
/// script is handling that breakpoint the trap is unhandled and the process dies on the
/// spot with EXC_BREAKPOINT/SIGTRAP - before reaching the code that explains how to
/// install a script. That produced a hard crash where a dialog was intended.
///
/// Probe it behind a SIGTRAP handler so an unhandled trap becomes a recoverable NO.
/// A debugger that IS attached takes the Mach exception first and never reaches the
/// signal handler, so the normal path is unaffected.
static sigjmp_buf jit26ProbeJmpBuf;

static void jit26ProbeTrapHandler(int sig) {
    siglongjmp(jit26ProbeJmpBuf, 1);
}

static BOOL probeJIT26CreateRegionLegacy(void **outResult) {
    struct sigaction probeAction, previousAction;
    memset(&probeAction, 0, sizeof(probeAction));
    probeAction.sa_handler = jit26ProbeTrapHandler;
    sigemptyset(&probeAction.sa_mask);
    probeAction.sa_flags = 0;
    if (sigaction(SIGTRAP, &probeAction, &previousAction) != 0) {
        // Cannot install the guard; fall back to the original unguarded behaviour.
        *outResult = JIT26CreateRegionLegacy(getpagesize());
        return YES;
    }

    BOOL handled;
    if (sigsetjmp(jit26ProbeJmpBuf, 1) == 0) {
        *outResult = JIT26CreateRegionLegacy(getpagesize());
        handled = YES;
    } else {
        *outResult = NULL;
        handled = NO;
    }
    sigaction(SIGTRAP, &previousAction, NULL);
    return handled;
}

/// Copy the bundled JIT script into POJAV_HOME so it is reachable from the Files app.
/// It used to be exported only after the breakpoint probe succeeded, which is useless:
/// a user who needs the script cannot get past the probe to obtain it.
static void exportJIT26ScriptIfNeeded(void) {
    const char *home = getenv("POJAV_HOME");
    if (!home) return;
    for (NSString *name in @[@"UniversalJIT26", @"JIT26Script"]) {
        NSString *source = [NSBundle.mainBundle pathForResource:name ofType:@"js"];
        if (!source) continue;
        NSString *dest = [NSString stringWithFormat:@"%s/%@.js", home, name];
        if ([fm fileExistsAtPath:dest]) continue;
        NSError *error = nil;
        [fm copyItemAtPath:source toPath:dest error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Could not export %@.js: %@", name, error.localizedDescription);
        } else {
            NSLog(@"[JavaLauncher] Exported %@.js to the Documents directory", name);
        }
    }
}

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Suppress [mvk-info] log spam (swapchain creation, etc.)
    // Aligned with the Ynnyny repo: suppress MoltenVK log spam so startup problems are easier to diagnose
    // But when the frame rate unlock is on, enable performance tracing temporarily to diagnose present-mode issues
    if (getPrefBool(@"video.disable_game_vsync")) {
        // Frame rate unlock diagnostics: enable MoltenVK performance tracing, which logs the frame rate and swapchain information
        // This helps confirm whether the present mode is IMMEDIATE in Vulkan mode
        setenv("MVK_CONFIG_PERFORMANCE_TRACKING", "1", 1);
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1); // Still suppresses info level, but the performance log is emitted
        // Try to force the present mode to IMMEDIATE (no waiting for vsync).
        // MoltenVK 1.2.5+ supports the MVK_CONFIG_SWAPCHAIN_PRESENT_MODE environment variable:
        //   0 = VK_PRESENT_MODE_IMMEDIATE_KHR (no vsync wait, so the frame rate can exceed the refresh rate)
        //   1 = VK_PRESENT_MODE_MAILBOX_KHR
        //   2 = VK_PRESENT_MODE_FIFO_KHR (the default, waits for vsync)
        // The MoltenVK actually running is 1.2.9 (confirmed from the libMoltenVK.dylib binary),
        // which supports this variable. The vk_mvk_moltenvk.h header in the repo is from an older version (1.1.2),
        // but the real dylib is 1.2.9, so the environment variable does take effect.
        // This is the key to unlocking the frame rate in Vulkan mode: the present mode is chosen entirely by
        // vkCreateSwapchainKHR, and the Vulkan renderer of MC 26.2 may not honor enableVsync=false correctly.
        // MoltenVK 1.2.9 reads this variable in vkCreateSwapchainKHR and overrides the presentMode the app asked for.
        setenv("MVK_CONFIG_SWAPCHAIN_PRESENT_MODE", "0", 1);
        NSLog(@"[JavaLauncher] MoltenVK performance tracking + IMMEDIATE present mode requested for VSync diagnosis");
    } else {
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1);
    }

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);

    // Unlock the frame rate (disabling vertical sync): read the launcher preference and pass it to the Java layer and the native bridge via an environment variable.
    //
    // The frame rate unlock works at three layers (each independent, backing each other up):
    //
    // 1. The Java layer (PojavLauncher.java), on seeing POJAV_DISABLE_VSYNC=1:
    //    a) forces enableVsync=false, so MC stops calling glfwSwapInterval(1)
    //    b) forces maxFps=260, since MC 1.16+ treats maxFps>=260 as "unlimited"
    //       (maxFps=0 was previously used, but MC ignores it as invalid, leaving the frame rate capped at maxFps=120)
    //
    // 2. The native bridge (egl_bridge.m pojavSwapInterval), on seeing POJAV_DISABLE_VSYNC=1:
    //    intercepts the glfwSwapInterval(1) call from MC and forces interval=0
    //    (logging every interception, which helps diagnose mods re-enabling VSync at runtime)
    //
    // 3. The EGL initialization layer (gl_bridge.m gl_make_current), on seeing POJAV_DISABLE_VSYNC=1:
    //    calls eglSwapInterval(0) immediately after eglMakeCurrent succeeds.
    //    This is the key to unlocking the frame rate on the zink renderer — when Mesa 21.0 zink lazily creates the Vulkan swapchain
    //    it picks the present mode from the current eglSwapInterval:
    //      interval=0 -> VK_PRESENT_MODE_IMMEDIATE_KHR (no vsync wait, so the frame rate can exceed 60)
    //      interval=1 -> VK_PRESENT_MODE_FIFO_KHR (waits for vsync, locked to the refresh rate)
    //    Setting it only when MC calls glfwSwapInterval would be too late — the swapchain may already have been created as FIFO,
    //    and Mesa 21.0 zink does not rebuild the swapchain dynamically, so the frame rate stays locked to the refresh rate.
    //
    // Notes on MoltenVK configuration and unlocking the Vulkan frame rate:
    //   The MoltenVK actually running is 1.2.9 (confirmed from the libMoltenVK.dylib binary).
    //   The vk_mvk_moltenvk.h header in the repo is from an older version (1.1.2, spec 30),
    //   but the real dylib is 1.2.9 and supports the MVK_CONFIG_SWAPCHAIN_PRESENT_MODE environment variable.
    //   MoltenVK 1.2.9 reads it in vkCreateSwapchainKHR and overrides the presentMode the app asked for,
    //   which is the key mechanism for unlocking the frame rate in Vulkan mode.
    //   Whether a device supports the IMMEDIATE present mode is detected automatically via
    //   MVKPhysicalDeviceMetalFeatures.presentModeImmediate (most iOS devices do).
    //
    //   The layers that unlock the frame rate in Vulkan mode:
    //   1. MC options: enableVsync=false + maxFps=260 (MC 1.16+ treats 260 as unlimited)
    //   2. MoltenVK config: MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0 -> IMMEDIATE present mode
    //      (supported by MoltenVK 1.2.9, overriding the presentMode the app picks in vkCreateSwapchainKHR)
    //   3. MC 26.2 compatibility: maxFps/maxFramerate/framerateLimit are all written, under each option name
    //
    // How well each renderer unlocks the frame rate:
    // - zink (GL->Vulkan): fully unlocked via eglSwapInterval(0) -> IMMEDIATE present mode
    // - Vulkan (LWJGL3): fully unlocked via MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0 -> IMMEDIATE present mode
    // - ANGLE Metal: eglSwapInterval(0) stops ANGLE waiting for vsync, so the render thread does not block
    // - ProMotion devices: 120Hz is enabled via CADisableMinimumFrameDurationOnPhone + preferredFrameRateRange
    setenv("POJAV_DISABLE_VSYNC", getPrefBool(@"video.disable_game_vsync") ? "1" : "0", 1);

    // Frame rate unlock diagnostics: log the key environment variables and preferences
    NSLog(@"[JavaLauncher] Framerate unlock configuration:");
    NSLog(@"[JavaLauncher]   video.disable_game_vsync=%d", getPrefBool(@"video.disable_game_vsync"));
    NSLog(@"[JavaLauncher]   POJAV_DISABLE_VSYNC=%s", getenv("POJAV_DISABLE_VSYNC"));
    NSLog(@"[JavaLauncher]   UIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

/// Load the MobileGlues configuration and write config.json
///
/// Writes the user preferences to <POJAV_HOME>/MG/config.json for the MobileGlues renderer to read.
///
/// How the renderers relate to MobileGlues (important):
/// - The MobileGlues renderer (libmobileglues.dylib): loads MobileGlues directly, so config.json takes effect.
/// - The Auto renderer: resolved to ANGLE (libtinygl4angle.dylib) in launchJVM, so MobileGlues is never loaded
///   and config.json is written but never read. The user must pick the MobileGlues renderer explicitly for the settings to apply.
/// - The Vulkan renderer: in Vulkan mode the OpenGL fallback library is MobileGlues (aligned with the Ynnyny repo),
///   so config.json is read by MobileGlues and does take effect.
void init_loadMobileGluesConfig() {
    NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    NSLog(@"[JavaLauncher] init_loadMobileGluesConfig: renderer=%@", renderer);

    BOOL usesMobileGlues = [renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES] ||
        [renderer isEqualToString:@"auto"] ||
        [renderer isEqualToString:@ RENDERER_NAME_VULKAN];

    if (!usesMobileGlues) {
        NSLog(@"[JavaLauncher] MobileGlues config not written (renderer is not mobileglues/auto/vulkan)");
        return;
    }

    // Warning: the auto renderer does not actually load MobileGlues, so these settings will not apply
    if ([renderer isEqualToString:@"auto"]) {
        NSLog(@"[JavaLauncher] WARNING: renderer is 'auto', will be resolved to ANGLE. "
              @"MobileGlues settings will NOT take effect. "
              @"Please explicitly select 'MobileGlues' renderer to use these settings.");
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        NSLog(@"[JavaLauncher] Vulkan renderer detected, MobileGlues used as GL fallback. Config will take effect.");
    } else {
        NSLog(@"[JavaLauncher] MobileGlues renderer detected, config will take effect.");
    }

    NSString *mgDirPath = [NSString stringWithFormat:@"%s/MG", getenv("POJAV_HOME")];
    setenv("MG_DIR_PATH", mgDirPath.UTF8String, 1);

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    // Safe defaults
    // Note: the Version(int code) constructor of MobileGlues turns the number into a string and takes the first 3 characters
    // as Major.Minor.Patch (settings.h lines 102-116). For example 40 -> "40" -> 4.0.0.
    // customGLVersion constraints (settings.cpp lines 71-79): >46 is clamped to 46, <32 and non-zero is clamped to 32,
    // 33-39 is clamped to 33, and 0 uses the default of 40.
    // A decimal number (40, 41, 42, ..., 46) must therefore be written, not the hexadecimal 0x040000.
    config[@"enableExtGL43"] = @1;
    config[@"enableExtDirectStateAccess"] = @1;
    config[@"maxGlslCacheSize"] = @128;
    config[@"customGLVersion"] = @40;  // Decimal 40 = GL 4.0

    id enableAngle = getPrefObject(@"mobileglues.enable_angle");
    if (enableAngle) {
        // The MobileGlues AngleConfig enum (settings.h):
        //   0 = DisableIfPossible
        //   1 = EnableIfPossible  <- on iOS hasVulkan12() always returns 0 (the #ifndef __APPLE__
        //                            block is skipped), so checkIfANGLESupported returns false and
        //                            ANGLE is disabled. This value cannot be used.
        //   2 = ForceDisable
        //   3 = ForceEnable       <- forces it on, bypassing GPU detection
        // When the user enables enable_angle, 3 (ForceEnable) is written; when disabled, 0 (DisableIfPossible)
        config[@"enableANGLE"] = [enableAngle boolValue] ? @3 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_angle = %@ -> enableANGLE = %@ (3=ForceEnable, 0=DisableIfPossible)",
              enableAngle, config[@"enableANGLE"]);
    }

    id enableNoError = getPrefObject(@"mobileglues.enable_no_error");
    if (enableNoError) {
        config[@"enableNoError"] = @([enableNoError intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.enable_no_error = %@ -> enableNoError = %@", enableNoError, config[@"enableNoError"]);
    }

    id enableExtTimerQuery = getPrefObject(@"mobileglues.enable_ext_timer_query");
    if (enableExtTimerQuery) {
        config[@"enableExtTimerQuery"] = [enableExtTimerQuery boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_timer_query = %@ -> enableExtTimerQuery = %@", enableExtTimerQuery, config[@"enableExtTimerQuery"]);
    }

    id enableExtComputeShader = getPrefObject(@"mobileglues.enable_ext_compute_shader");
    if (enableExtComputeShader) {
        config[@"enableExtComputeShader"] = [enableExtComputeShader boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_compute_shader = %@ -> enableExtComputeShader = %@", enableExtComputeShader, config[@"enableExtComputeShader"]);
    }

    id enableExtDirectStateAccess = getPrefObject(@"mobileglues.enable_ext_direct_state_access");
    if (enableExtDirectStateAccess) {
        config[@"enableExtDirectStateAccess"] = [enableExtDirectStateAccess boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_direct_state_access = %@ -> enableExtDirectStateAccess = %@", enableExtDirectStateAccess, config[@"enableExtDirectStateAccess"]);
    }

    id maxGlslCacheSize = getPrefObject(@"mobileglues.max_glsl_cache_size");
    if (maxGlslCacheSize) {
        config[@"maxGlslCacheSize"] = @([maxGlslCacheSize intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.max_glsl_cache_size = %@ -> maxGlslCacheSize = %@", maxGlslCacheSize, config[@"maxGlslCacheSize"]);
    }

    id multidrawMode = getPrefObject(@"mobileglues.multidraw_mode");
    if (multidrawMode) {
        config[@"multidrawMode"] = @([multidrawMode intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.multidraw_mode = %@ -> multidrawMode = %@", multidrawMode, config[@"multidrawMode"]);
    }

    id angleDepthClearFixMode = getPrefObject(@"mobileglues.angle_depth_clear_fix_mode");
    if (angleDepthClearFixMode) {
        config[@"angleDepthClearFixMode"] = [angleDepthClearFixMode boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.angle_depth_clear_fix_mode = %@ -> angleDepthClearFixMode = %@", angleDepthClearFixMode, config[@"angleDepthClearFixMode"]);
    }

    id customGlVersion = getPrefObject(@"mobileglues.custom_gl_version");
    if (customGlVersion) {
        NSString *verStr = [customGlVersion description];
        NSLog(@"[JavaLauncher]   mobileglues.custom_gl_version = %@ (raw)", customGlVersion);
        // MobileGlues expects a decimal number: Version(int code) turns code into a string and takes the first 3 characters as
        // Major.Minor.Patch. For example 40 -> "40" -> 4.0.0 and 46 -> "46" -> 4.6.0.
        // The hexadecimal 0x040000 (=262144) cannot be used, as it would be truncated to 46 (4.6.0).
        if ([verStr isEqualToString:@"3.0"]) config[@"customGLVersion"] = @30;
        else if ([verStr isEqualToString:@"3.1"]) config[@"customGLVersion"] = @31;
        else if ([verStr isEqualToString:@"3.2"]) config[@"customGLVersion"] = @32;
        else if ([verStr isEqualToString:@"3.3"]) config[@"customGLVersion"] = @33;
        else if ([verStr isEqualToString:@"4.0"]) config[@"customGLVersion"] = @40;
        else if ([verStr isEqualToString:@"4.1"]) config[@"customGLVersion"] = @41;
        else if ([verStr isEqualToString:@"4.2"]) config[@"customGLVersion"] = @42;
        else if ([verStr isEqualToString:@"4.3"]) config[@"customGLVersion"] = @43;
        else if ([verStr isEqualToString:@"4.4"]) config[@"customGLVersion"] = @44;
        else if ([verStr isEqualToString:@"4.5"]) config[@"customGLVersion"] = @45;
        else if ([verStr isEqualToString:@"4.6"]) config[@"customGLVersion"] = @46;
        // When verStr == @"0" nothing matches and the default of @40 (GL 4.0) is kept
        NSLog(@"[JavaLauncher]   -> customGLVersion = %d (decimal, MobileGlues Version(int) format)",
              [config[@"customGLVersion"] intValue]);
    }

    id fsr1Setting = getPrefObject(@"mobileglues.fsr1_setting");
    if (fsr1Setting) {
        config[@"fsr1Setting"] = @([fsr1Setting intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.fsr1_setting = %@ -> fsr1Setting = %@", fsr1Setting, config[@"fsr1Setting"]);
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [fm createDirectoryAtPath:mgDirPath withIntermediateDirectories:YES attributes:nil error:nil];
        [jsonString writeToFile:[mgDirPath stringByAppendingPathComponent:@"config.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[JavaLauncher] MobileGlues config written to %@/config.json", mgDirPath);
        NSLog(@"[JavaLauncher] config.json content:\n%@", jsonString);
    } else {
        NSLog(@"[JavaLauncher] Failed to serialize MobileGlues config: %@", error);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    // Key fix (N3+N4): retainedCustomFlags holds a strong reference to every custom JVM flag string,
    // so the C string returned by [@"-" stringByAppendingString:jvmarg].UTF8String cannot dangle.
    //
    // Previously argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String took UTF8String straight from a temporary
    // NSString, and an autoreleased NSString is freed once the runloop drains,
    // leaving a dangling pointer in argv. launchJava normally does not drain the autorelease pool before the JVM starts,
    // but that is a fragile implicit dependency. retainedCustomFlags is static, so its lifetime spans the whole process
    // and the strings are guaranteed valid for the duration of the pJLI_Launch call.
    static NSMutableArray<NSString *> *retainedCustomFlags = nil;
    if (retainedCustomFlags == nil) {
        retainedCustomFlags = [NSMutableArray array];
    }
    // Note: retainedCustomFlags is never cleared, because launchJava is called only once per process.
    // If it ever becomes callable more than once, it must be cleared beforehand.

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        // N3 bounds check: the argv array size is decided by the caller (margv[1000]), so check defensively here
        if (*argc + 1 >= 1000) {
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding custom JVM flag: -%@", jvmarg);
            continue;
        }
        NSString *flagStr = [@"-" stringByAppendingString:jvmarg];
        [retainedCustomFlags addObject:flagStr];
        ++*argc;
        argv[*argc] = flagStr.UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *accountId, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // Synced from catsruledogs: refresh the JIT flags to decide whether Debug JIT Mapping is needed
    // Uses DeviceNeedsDebugJITMapping() based on JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED
    // rather than TXM firmware detection, so the JIT script is set correctly on iOS 26+ devices without TXM too
    DeviceGetJITFlags(YES);
    BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresDebugJITMapping) {
        // Make the script reachable before it is needed, not after.
        exportJIT26ScriptIfNeeded();

        // Detect whether a legacy JIT script is in use (brk #0x69 is handled by UniversalJIT26.js)
        static void *result;
        static BOOL probed;
        if (!probed) {
            probed = YES;
            if (!probeJIT26CreateRegionLegacy(&result)) {
                // Nothing trapped the breakpoint, so no JIT script is attached. Say so
                // instead of dying at the breakpoint with no explanation.
                UIKit_returnToSplitView();
                showDialog(localize(@"Error", nil),
                           @"No JIT script is attached.\n\n"
                           "JIT is enabled, but enabling JIT and assigning a script are two separate steps, "
                           "and the launcher needs the script to allocate its JIT region.\n\n"
                           "In StikDebug, long-press Air while enabling JIT, tap \"Assign Script\", then pick "
                           "UniversalJIT26.js - it has been placed in Air's Documents folder for you. "
                           "(On sideloaded StikDebug the built-in script is named Amethyst-MeloNX.js.)");
                [PLLogOutputView handleExitCode:1];
                return 1;
            }
        }
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            // The legacy script only allows the breakpoint to be called once, so it must switch to UniversalJIT26
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if(lcAppInfo) {
                // Inside LiveContainer: assign the script automatically and ask the user to restart
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if (!requiresDebugJITMapping || jit26AlwaysAttached) {
        if (jit26AlwaysAttached) {
            // Only allow StikDebug to catch our breakpoints to prevent any stutters
            task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
                EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        }
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    } else {
        NSLog(@"[DyldLVBypass] Hook disabled! Loading unsigned dylib will cause code signature error.");
    }

    // Load the MobileGlues configuration (only effective when the user picked the MobileGlues renderer explicitly)
    init_loadMobileGluesConfig();

    // --- [Update] TouchController transport support ---
    // Check whether TouchController is enabled and which transport was chosen
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 1) { // UDP mode
            setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with UDP mode");
        } else if (mode == 2) { // Static library mode
            // Set the Unix domain socket path
            setenv("TOUCH_CONTROLLER_PROXY_SOCKET", "/tmp/touchcontroller.sock", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with Static Library mode");
        }
    }
    // ------------------------------------------

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        // 26.x officially requires Java 25 (Mojang set javaVersion.majorVersion to 25 from 26.x onwards),
        // so preferredJavaVersion is no longer clamped at all and the Java version specified by the profile is used as-is.
        // The three-way caciocavallo switch picks the matching jar for the actual Java version (three separate folders):
        // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT）
        // - Java 17/21 -> libs_caciocavallo17 (1.18-SNAPSHOT, compiled purely for Java 17)
        // - Java 25    -> libs_caciocavallo25 (1.18-SNAPSHOT, containing Java 24 classes, catsruledogs iOS)
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion (%d)", preferredJavaVersion);
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Setup AMETHYST_RENDERER
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);

        // Apply Zink-specific environment variables if Zink renderer is selected
        // Companion to the Mesa 25.0.7 zink upgrade: MESA_GL_VERSION_OVERRIDE,
        // MESA_GLSL_VERSION_OVERRIDE, MESA_EXTENSION_OVERRIDE, mesa_glthread, the shader cache and so on are tuned automatically for the device GPU generation.
        // The ZinkConfig Auto level keeps every GL extension shaders need (compute/tessellation/geometry
        // shaders and the like) and only disables Transform Feedback, which MoltenVK supports poorly, so Iris/OptiFine are unaffected.
        if ([renderer hasPrefix:@"libOSMesa"]) {
            [ZinkConfig applyZinkEnvironmentFromPreferences];
            NSString *configSummary = [ZinkConfig activeConfigSummary];
            NSLog(@"[ZinkConfig] ========== Zink Renderer Active (Mesa 25) ==========");
            NSLog(@"[ZinkConfig] %@", configSummary);
            setenv("ZINK_ACTIVE_CONFIG", configSummary.UTF8String, 1);

            // Install the zink 4-byte vertex stride alignment fix
            // Fixes the crash where Mesa 25.0.7 zink + MoltenVK failed vkCreateGraphicsPipelines
            // because the stride was not 4-byte aligned when shaders were enabled -> SIGSEGV (see main_hook.m)
            // It must be called before libOSMesa is dlopen-ed, so fishhook can intercept the later symbol references
            installZinkStrideFix();
        }

        // Apply LTW-specific environment variables if LTW renderer is selected
        // LTW (Large Thin Wrapper) OpenGL Core 3.3 -> ES 3 translation layer
        // No LTW_* environment variables are set, so the defaults from the LTW main.c constructor apply (matching Android)
        //   - LIBGL_ES: LTW detects the ES version itself
        //   - LTW_NEVER_FLUSH_BUFFERS: true by default
        //   - LTW_COHERENT_DYNAMIC_STORAGE: true by default
        // Only POJAVEXEC_EGL is set, marking EGL as provided by LTW (matching the Android semantics)
        if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
            setenv("POJAVEXEC_EGL", RENDERER_NAME_LTW, 1);
            NSLog(@"[JavaLauncher] LTW renderer active: using LTW defaults (same as Android)");
        }
        // Setup AMETHYST_GRAPHICS_API（MC 26.2+ Graphics API：default/vulkan/opengl）
        // Only MC 26.2+ understands this option; older versions ignore the graphicsApi field in options.txt.
        //
        // Key fix (changing the graphics API had no effect):
        //   the environment variable used to be set only when graphicsApi was non-empty, which meant:
        //   1. the variable was missing if the user had never set graphicsApi, so the Java side could not clear the old value
        //   2. with the variable missing, the Java side skipped the graphicsApi handling entirely
        //   It is now always set (defaulting to "default"), so the Java side handles it correctly on every launch:
        //   - "default": remove the graphicsApi line from options.txt
        //   - prefer_vulkan/prefer_opengl: write the matching value
        NSString *graphicsApi = [PLProfiles resolveKeyForCurrentProfile:@"graphicsApi"];
        if (!graphicsApi || graphicsApi.length == 0) {
            graphicsApi = @"default";
        }
        setenv("AMETHYST_GRAPHICS_API", graphicsApi.UTF8String, 1);
        NSLog(@"[JavaLauncher] GRAPHICS_API is set to %@\n", graphicsApi);

        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
        // For the execute_jar path (such as the OptiFine installer), caciocavallo is handled by the three-way switch:
        // whichever Java runtime is actually selected, the caciocavallo jar from the matching folder is used.
        // minVersion is no longer forced up or clamped here.
    }

    // 26.x officially requires Java 25 (Mojang set javaVersion.majorVersion to 25 from 26.x onwards).
    // The profile javaVersion is no longer clamped: 26.x must launch on Java 25.
    // The three-way caciocavallo switch (following the binary approach of FCL/ZalithLauncher2, extended to three for Java 25):
    // three separate sibling folders, chosen by the actual Java version:
    // - Java 8     -> libs_caciocavallo (1.10-SNAPSHOT, package net.java.openjdk.cacio, bootclasspath/p)
    // - Java 17/21 -> libs_caciocavallo17 (1.18-SNAPSHOT compiled purely for Java 17, package com.github.caciocavallosilano.cacio, bootclasspath/a)
    // - Java 25    -> libs_caciocavallo25 (1.18-SNAPSHOT containing Java 24 classes, package com.github.caciocavallosilano.cacio, bootclasspath/a)
    //   From catsruledogs/Amethyst-iOS-25. Its CTCGraphicsEnvironment is a Java 24 class (class version 68)
    //   with Java 25 compatibility fixes; the purely Java 17 build SIGSEGVs during get_method_id.
    //   Class version 68 only loads on Java 24+, so Java 17/21 cannot share it and need the pure Java 17 jar from the caciocavallo17 folder.

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    if (!validateVirtualMemorySpace(allocmem)) {
        // Sideloaded builds usually lose com.apple.developer.kernel.increased-memory-limit:
        // the entitlement is in entitlements.sideload.xml, but re-signing with a personal
        // provisioning profile that does not authorise it strips it back out. iOS then
        // refuses a mapping this large and the launcher gave up entirely - on an 8 GB
        // device auto-RAM asks for 2048 MB, which a jailed process cannot map.
        //
        // Step the heap down until something fits rather than refusing to start. This
        // only runs where the old code would have failed outright, so a setup that
        // already worked is unaffected.
        const int kMinimumAllocMB = 512;
        int workable = 0;
        for (int candidate = allocmem * 3 / 4; candidate >= kMinimumAllocMB; candidate = candidate * 3 / 4) {
            if (validateVirtualMemorySpace(candidate)) {
                workable = candidate;
                break;
            }
        }
        if (workable > 0) {
            NSLog(@"[JavaLauncher] %d MB could not be mapped; falling back to %d MB", allocmem, workable);
            allocmem = workable;
        } else {
            UIKit_returnToSplitView();
            if (getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")) {
                showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
            } else {
                showDialog(localize(@"Error", nil),
                           [NSString stringWithFormat:
                            @"Insufficient contiguous virtual memory space.\n\n"
                            "Even %d MB could not be mapped. This build lost the Increased Memory Limit "
                            "entitlement when it was re-signed for sideloading.\n\n"
                            "Try turning off automatic RAM in Settings and setting the allocation lower, "
                            "or install through TrollStore or LiveContainer (with GetMoreRam), which keep "
                            "the entitlement.", kMinimumAllocMB]);
            }
            return 1;
        }
    }

    int margc = -1;
    const char *margv[1000];

    // Key fix (N3+N4): margv bounds checking + string lifetime management
    //
    // N3 (bounds checking):
    //   margv[1000] is a fixed-size array, and no margv[++margc] = ... ever checked whether margc had run past the end.
    //   Adding arguments later could overflow the stack buffer. The PUSH_MARGV_* macros add a defensive bounds check.
    //
    // N4 (dangling pointers):
    //   The C string returned by [NSString stringWithFormat:...].UTF8String depends on the lifetime of an autoreleased
    //   NSString. launchJVM currently has no explicit @autoreleasepool around its body, so autoreleased
    //   objects land in the thread pool and are only freed at the next runloop drain. Since the function ends by immediately
    //   calling pJLI_Launch(margc, margv, ...) with no drain in between, it happens to be safe.
    //   But that is a fragile implicit dependency: if someone later inserts an @autoreleasepool block or a drain,
    //   every pointer in margv produced by stringWithFormat: dangles at once and the JVM crashes on startup.
    //
    //   Fix: hold every NSString created by stringWithFormat: strongly in the retainedStrings array,
    //   so their lifetime covers the pJLI_Launch call. retainedStrings is a local strong reference and is released
    //   automatically when the function returns, so nothing needs managing by hand.
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    // Macro: safely append a literal argument to margv
    // String literals (such as "-XstartOnFirstThread") are const char* with static storage duration and never expire
    // Bounds check: stop appending once margc reaches the limit, to avoid a stack overflow
    #define PUSH_MARGV_LITERAL(literal) do { \
        if (margc + 1 < 1000) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding literal argument %s", (literal)); \
        } \
    } while (0)

    // Macro: build an argument with stringWithFormat: and append it to margv
    // The NSString created is held strongly by retainedStrings until the function returns,
    // so the UTF8String pointers stored in margv stay valid for the duration of the pJLI_Launch call.
    // Note: the NSLog warning does not use fmt as the format string (so a % is not misparsed) and only prints a literal hint.
    #define PUSH_MARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 1000) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding formatted argument"); \
        } \
    } while (0)

    PUSH_MARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_MARGV_LITERAL("-XstartOnFirstThread");
    if (!launchJar) {
        PUSH_MARGV_LITERAL("-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader");
    }
    PUSH_MARGV_LITERAL("-Xms128M");
    PUSH_MARGV_FORMAT(@"-Xmx%dM", allocmem);
    // library.path: a single Frameworks path (aligned with the Ynnyny repo)
    //
    // Key fix (26.2 startup crash): the workspace used to split the LWJGL dylibs into lwjgl33/ and lwjgl34/ subfolders
    // and pick a path by scanning the LWJGL declaration in the version JSON. But the Ynnyny repo launches 26.2 fine with a single
    // Frameworks path, showing the split is unnecessary and that misplaced dylibs would load the wrong native library version.
    //
    // Now aligned with Ynnyny: every native dylib (LWJGL-specific and shared alike) lives in the Frameworks/ root and
    // library.path = Frameworks. The customized root lwjgl.jar (with the iOS-specific LWJGL patches) is merged into the final
    // lwjgl.jar by JavaApp/Makefile, so LWJGL loads the GL implementation correctly on iOS.
    NSString *frameworksPath = [NSString stringWithFormat:@"%@/Frameworks", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-Djava.library.path=%@", frameworksPath);
    NSLog(@"[JavaLauncher] library.path = %@", frameworksPath);
    PUSH_MARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_MARGV_FORMAT(@"-Duser.home=%s", getenv("POJAV_HOME"));
    PUSH_MARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_MARGV_FORMAT(@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);

    // Publish the GameSurfaceView pointer for the Metallum Metal backend
    // +[SurfaceViewController surface] returns the static pojavWindow, which is assigned in
    // -[SurfaceViewController viewDidLoad] (before launchMinecraft is dispatched to this background thread).
    // Passing the pointer through a system property avoids the JVM render thread having to look up the UIView through the ObjC runtime.
    Class surfaceVCClass = NSClassFromString(@"SurfaceViewController");
    if (surfaceVCClass && [surfaceVCClass respondsToSelector:@selector(surface)]) {
        id surfaceView = [surfaceVCClass performSelector:@selector(surface)];
        if (surfaceView) {
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.view.pointer=%p", surfaceView);
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.screen.scale=%g", (double)UIScreen.mainScreen.scale);
            NSLog(@"[JavaLauncher] Published Metallum surface view: %p (scale=%g)", surfaceView, (double)UIScreen.mainScreen.scale);
        } else {
            NSLog(@"[JavaLauncher] Warning: +[SurfaceViewController surface] returned nil, Metallum will fall back to ObjC runtime lookup");
        }
    } else {
        NSLog(@"[JavaLauncher] Warning: SurfaceViewController class unavailable, Metallum will fall back to ObjC runtime lookup");
    }

    PUSH_MARGV_LITERAL("-Dorg.lwjgl.glfw.checkThread0=false");
    PUSH_MARGV_LITERAL("-Dorg.lwjgl.system.allocator=system");
    //PUSH_MARGV_LITERAL("-Dorg.lwjgl.util.NoChecks=true");
    PUSH_MARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");

    // ============================================================================
    // JNA load path
    // ============================================================================
    // The darwin-aarch64 libjnidispatch of JNA 5.13.0 loads fine once extracted from the JAR.
    // Tools.java / MinecraftResourceUtils.m force JNA down to 5.13.0
    // (the 5.17.0 required by MC 26.3+ causes a native crash on iOS).
    // boot.library.path is kept so an iOS arm64 libjnidispatch can be bundled in future.
    PUSH_MARGV_FORMAT(@"-Djna.boot.library.path=%@", frameworksPath);

    // ============================================================================
    // Frame rate unlock, layer 4: a JVM system property
    // ============================================================================
    // Some MC versions/mods may read the frame rate limit via System.getProperty.
    // -Dmax.fps=260 is set as an extra safety net beyond options.txt.
    // It has no effect on versions that do not read the property.
    if (getPrefBool(@"video.disable_game_vsync")) {
        PUSH_MARGV_LITERAL("-Dmax.fps=260");
        NSLog(@"[JavaLauncher] Added JVM property -Dmax.fps=260 (frame rate unlock layer 4)");
    }

    // ============================================================================
    // ZeroTier multiplayer SOCKS5 proxy injection — temporarily removed (while a startup crash is investigated)
    // ============================================================================
    // Original behavior: detect the AMETHYST_SOCKS5_PROXY environment variable and inject -DsocksProxyHost/-DsocksProxyPort
    // With ZeroTier temporarily removed, MultiplayerManager no longer sets that variable, so this block is commented out
    // ============================================================================
    // const char *socks5ProxyEnv = getenv("AMETHYST_SOCKS5_PROXY");
    // if (socks5ProxyEnv && socks5ProxyEnv[0] != '\0') {
    //     NSString *proxyStr = [NSString stringWithUTF8String:socks5ProxyEnv];
    //     NSRange colonRange = [proxyStr rangeOfString:@":"];
    //     if (colonRange.location != NSNotFound && colonRange.location > 0 &&
    //         colonRange.location + 1 < proxyStr.length) {
    //         NSString *proxyHost = [proxyStr substringToIndex:colonRange.location];
    //         NSString *proxyPortStr = [proxyStr substringFromIndex:colonRange.location + 1];
    //         NSInteger portValue = [proxyPortStr integerValue];
    //         if (portValue > 0 && portValue <= 65535) {
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyHost=%@", proxyHost);
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyPort=%@", proxyPortStr);
    //             NSString *nonProxyHosts = @"localhost|127.*|[::1]|"
    //                                       @"*.minecraft.net|*.mojang.com|"
    //                                       @"*.microsoft.com|*.microsoftonline.com|"
    //                                       @"*.xboxlive.com|*.modrinth.com|"
    //                                       @"*.curseforge.com|*.githubusercontent.com|"
    //                                       @"*.github.com|*.amazonaws.com|"
    //                                       @"*.cloudfront.net|*.akamaihd.net|"
    //                                       @"10.*|192.168.*|172.16.*|172.17.*|172.18.*|"
    //                                       @"172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|"
    //                                       @"172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|"
    //                                       @"172.29.*|172.30.*|172.31.*";
    //             PUSH_MARGV_FORMAT(@"-DsocksNonProxyHosts=%@", nonProxyHosts);
    //             NSLog(@"[JavaLauncher] Injected ZeroTier SOCKS5 proxy: %@:%@", proxyHost, proxyPortStr);
    //         }
    //     }
    // }

    // Preset OpenGL libname
    const char *glLibName = getenv("AMETHYST_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // Key fix (26.2 startup crash): the Auto renderer always picks ANGLE (aligned with the Ynnyny repo)
            //
            // The workspace used to prefer MobileGlues on Java 21+, but the Ynnyny repo launches 26.2 fine with ANGLE.
            // Picking MobileGlues without also calling init_loadMobileGluesConfig() to write config.json meant
            // MobileGlues initialized the GL context with unsafe defaults and could crash. It now always picks ANGLE, as Ynnyny does.
            // MobileGlues remains available as a manual option (the user can select it explicitly in settings).
            glLibName = RENDERER_NAME_MTL_ANGLE;
            setenv("AMETHYST_RENDERER", glLibName, 1);
            NSLog(@"[JavaLauncher] Auto renderer resolved to %s (always ANGLE)", glLibName);
        }
        if (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0) {
            // Aligned with the Ynnyny repo: in Vulkan mode the OpenGL fallback library is MobileGlues
            //
            // libMoltenVK is a Vulkan loader, not a GL implementation, so binding it as opengl.libname makes
            // LWJGL fail to find the GL symbols. But NativeLibrariesBootstrap.loadOpenGL() in MC 26.2
            // initializes org.lwjgl.opengl.GL at startup (whichever renderer the game ends up using).
            // With opengl.libname unset, LWJGL falls back to MacOSXLibraryBundle.getWithIdentifier
            // ("com.apple.opengl"), which fails on iOS because there is no system OpenGL framework ->
            //   UnsatisfiedLinkError: Failed to retrieve bundle with identifier: com.apple.opengl
            // Point it at libmobileglues.dylib: MobileGlues is designed for GL-on-Metal/Vulkan
            // and already uses the shipped libspirv-cross.dylib for shader translation. GL.create() finds the GL function pointers,
            // and if MC calls a GL entry point (compat code, shader building and so on) MobileGlues routes it through Vulkan
            // instead of crashing the way a context-less gl4es would.
            //
            // Note: vulkan.libname is not set here (matching Ynnyny); PojavLauncher.java sets it via
            // System.setProperty("org.lwjgl.vulkan.libname", "MoltenVK").
            // Passing "libMoltenVK.dylib" through -D here would make LWJGL Library.loadNative add the "lib" prefix and
            // ".dylib" suffix, producing "liblibMoltenVK.dylib.dylib" (the wrong file name).
            //
            // MoltenVK configuration (aligned with Ynnyny):
            // - RESUME_LOST_DEVICE=1: recover automatically after a lost device
            // - SYNCHRONOUS_QUEUE_SUBMITS=1: synchronous queue submission (more stable, avoiding races)
            // - PREFILL_METAL_COMMAND_BUFFERS=1: prefill the Metal command buffers (less GPU waiting, a performance win)
            setenv("MVK_CONFIG_RESUME_LOST_DEVICE", "1", 1);
            setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "1", 1);
            setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "1", 1);
        }
        // Aligned with Ynnyny: use a separate openglLibName variable and leave glLibName untouched (its original value is needed for later checks)
        const char *openglLibName = (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0)
            ? RENDERER_NAME_MOBILEGLUES
            : glLibName;

        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", openglLibName);

        // Key fix (following FCL, phase 4: switching the graphics API had no effect on 26.2):
        // org.lwjgl.vulkan.libname used to be set only when renderer=libMoltenVK.dylib, via System.setProperty in PojavLauncher.java,
        // so a user who kept the default renderer=auto (resolved to ANGLE) and switched
        // graphicsApi=prefer_vulkan left LWJGL unable to find the Vulkan library -> MC silently fell back to OpenGL.
        //
        // What FCL does: set the native libraries for both the OpenGL and Vulkan paths through -D system properties before the JVM starts,
        // so whichever path MC takes, the matching library is found.
        //
        // Pass the bare name "MoltenVK": LWJGL Library.loadNative adds the "lib" prefix and ".dylib" suffix itself,
        // producing "libMoltenVK.dylib" (the correct file name). Passing "libMoltenVK.dylib" would be wrapped into
        // "liblibMoltenVK.dylib.dylib" (the wrong file name).
        //
        // Safety: even if MC ends up on the GL path, loading MoltenVK has no side effects (the GL path never calls a Vulkan entry point).
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.vulkan.libname=MoltenVK");

        // Specify the spirv-cross library name explicitly (following catsruledogs/Amethyst-iOS-25):
        // the LWJGL spvc module looks for "spirv-cross" by default -> loading libspirv-cross.dylib (the standard macOS name),
        // but the actual file is libspirv-cross-c-shared.0.dylib (an SO name with a version suffix).
        // Setting -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0 explicitly makes LWJGL Library.loadNative
        // add the "lib" prefix and ".dylib" suffix, producing "libspirv-cross-c-shared.0.dylib",
        // which is found on library.path (Frameworks).
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0");
    }

      // Add the authlib-injector arguments so third-party accounts can show their skins
    if ([accountId length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    // arg comes from the authlibArgs array and is a strong reference, but the array itself may be
                    // released outside the loop, so PUSH_MARGV_FORMAT persists it to prevent dangling
                    PUSH_MARGV_FORMAT(@"%@", arg);
                    NSLog(@"[JavaLauncher] Added authlib-injector arg: %s", arg.UTF8String);
                }     
            } else {
                NSLog(@"[JavaLauncher] Warning: No authlib-injector arguments available");
            }
        }
    }
  
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-javaagent:%@/patchjna_agent.jar=", librariesPath);
    if(getPrefBool(@"general.cosmetica")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath);
    }
    if(getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/patchsvc.jar=", librariesPath);
    }

    // Workaround random stack guard allocation crashes
    PUSH_MARGV_LITERAL("-XX:+UnlockExperimentalVMOptions");
    PUSH_MARGV_LITERAL("-XX:+DisablePrimordialThreadGuardPages");

    // Key fix (liblwjgl_stb SIGILL crash, a full CodeCache):
    //   The crash log showed "CodeCache is full. Compiler has been disabled." immediately before a SIGILL
    //   at liblwjgl_stb.dylib+0x4d26c. The reproduction paths included:
    //   - 1.16.5 + libOSMesa + zink + MoltenVK（Java 8）
    //   - 1.20.1 + Forge + mobileglues（Java 17）
    //   which shows the root cause is unrelated to the renderer and is simply insufficient CodeCache capacity.
    //
    //   The project never set any CodeCache parameters and relied entirely on the JVM defaults:
    //   - Java 8 defaults to ReservedCodeCacheSize=48MB
    //   - Java 17+ defaults to 240MB (which can still be tight under heavy native loading)
    //
    //   Once the CodeCache fills, JIT-compiled methods are partially invalidated and the CPU runs into a corrupted instruction sequence
    //   -> SIGILL (the crash lands in liblwjgl_stb because stb_truetype font rasterization is the first
    //   heavily JIT-ed native wrapper, not because of the renderer).
    //
    //   Fix: set it to 64m, which applies to Java 8/17/21/25 alike.
    //   - 64m is still 33% above the Java 8 default (48MB), enough to avoid the SIGILL from a full CodeCache
    //   - InitialCodeCacheSize=16m avoids triggering a CodeCache expansion right at startup (the default 2.25m
    //     expands several times, and each expansion takes a global lock)
    //   - CodeCacheExpansionSize=4m reduces the number of expansions (the 64K default is far too small)
    //   - +UnlockExperimentalVMOptions is already enabled on the previous line and does not need repeating
    //
    //   iOS 27 SIGBUS fix (non-TXM devices, e.g. A15):
    //   On iOS 26+, -XX:+MirrorMappedCodeCache maps JIT code into RX memory
    //   allocated by the StikDebug debugger. With 256m, the mirrored region
    //   extends into pages whose executability is unreliable, causing intermittent
    //   SIGBUS when JIT-compiled code lands on those pages. The crash is
    //   intermittent because it depends on how much JIT code the JVM generates
    //   at runtime - if it stays within the safe region, the app exits normally.
    //   Reducing to 64m constrains the mirror mapping within the debugger's
    //   reliably allocated RX region, eliminating the SIGBUS.
    //   Repro: iOS 27 + A15 (no TXM) + StikDebug + Java 21 (MC 1.21.1).
    //   Java 25 (MC 26.2+) is unaffected - its JIT handles mirror mapping
    //   more robustly and doesn't trigger the crash even with 256m.
    PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
    PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=16m");
    PUSH_MARGV_LITERAL("-XX:CodeCacheExpansionSize=4m");

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        PUSH_MARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }

    // Disable Forge 1.16.x early progress window
    PUSH_MARGV_LITERAL("-Dfml.earlyprogresswindow=false");

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];

    // ============================================================================
    // JVM performance tuning (conservative parameters that do not affect startup stability)
    // ============================================================================
    // G1GC tuning is only enabled for Java 17+. The G1GC of Java 8 is not mature enough, so it keeps the default SerialGC.
    // Parameters that could hurt the gameplay experience are deliberately not added: -XX:+AlwaysPreTouch (which lengthens startup),
    // -XX:TieredStopAtLevel=1 (which lowers JIT performance), -XX:CICompilerCount=1 (which cuts compiler threads) and the like.
    // -XX:+UnlockExperimentalVMOptions is added above, and UseStringDeduplication needs experimental mode.
    if (!isJava8) {
        // G1GC: the default GC from Java 9+, enabled explicitly for consistency.
        // It suits large heaps (MC usually gets 2-4GB) and reduces full GC pauses.
        PUSH_MARGV_LITERAL("-XX:+UseG1GC");
        // Target a 50ms GC pause (the default is 200ms).
        // This is a soft target the JVM tries to meet without enforcing it, so it cannot cause an OOM.
        // It helps the real-time rendering of MC by reducing GC-induced stutter.
        PUSH_MARGV_LITERAL("-XX:MaxGCPauseMillis=50");
        // String deduplication: a G1GC feature that automatically deduplicates equal String objects in the old generation.
        // MC has many duplicate strings (block names, item names, I18N keys and so on), so this saves 5-10% of the heap.
        // It only works under G1GC and its overhead is tiny.
        PUSH_MARGV_LITERAL("-XX:+UseStringDeduplication");
        NSLog(@"[JavaLauncher] JVM GC optimization: G1GC + MaxGCPauseMillis=50 + StringDeduplication (Java 17+)");
    } else {
        NSLog(@"[JavaLauncher] Java 8 detected, skipping G1GC tuning (using default GC)");
    }

    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    PUSH_MARGV_LITERAL("-Djava.awt.headless=false");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontmanager=sun.awt.X11FontManager");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler");
    PUSH_MARGV_FORMAT(@"-Dcacio.managed.screensize=%dx%d", width, height);
    PUSH_MARGV_LITERAL("-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel");
    if (isJava8) {
        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment");
    } else {
        // Enable native access (supported from Java 17+, mandatory on Java 25).
        // Following catsruledogs/Amethyst-iOS-25: Java 25 restricts restricted methods (@Restricted, covering JNI,
        // sun.misc.Unsafe and the Foreign API) more tightly, and without this flag the native access of caciocavallo/LWJGL/JNA
        // takes the warning path, which on unnamed-module classes from bootclasspath/a can make
        // get_method_id read inconsistent class metadata and SIGSEGV (the root cause of the 26.2 startup crash).
        // The log line "WARNING: Use --enable-native-access=ALL-UNNAMED to avoid a warning"
        // says the same thing. Adding it on Java 17/21 has no side effects, so it is added for every non-Java-8 branch.
        // Key fix (26.2 startup crash): remove --enable-native-access=ALL-UNNAMED (aligned with the Ynnyny repo)
        // The Ynnyny repo launches 26.2 fine without it, showing the earlier diagnosis (that Java 25 required it) was wrong.
        // The flag changes the restricted-method warning path for unnamed modules and may disturb the initialization order
        // of the caciocavallo classes on bootclasspath/a.

        // Required by Cosmetica to inject DNS
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.net=ALL-UNNAMED");

        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment");

        // Required by Caciocavallo17 to access internal API
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.base/sun.security.action=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.util=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.lang.reflect=ALL-UNNAMED");
        // Following catsruledogs/Amethyst-iOS-25: do not add the sun.awt / sun.awt.image / java.awt.peer
        // add-opens. catsruledogs launches 26.2 + Java 25 fine without them.
        // Adding those 3 opens caused the graphics environment to initialize too early on Java 25,
        // triggering get_method_id -> SIGSEGV before the CTCGraphicsEnvironment of caciocavallo25 had registered.
        // The purely Java 17 build, caciocavallo17 (used on Java 17/21), does not need them:
        // its CTCGraphicsEnvironment reaches the internal APIs it needs through --add-exports (added above).

        // Export of the cpw.mods.bootstraplauncher module: added for every Java version (following catsruledogs/Amethyst-iOS-25).
        // It was previously added only for Java 17/21 and skipped on Java 25, which scrambled class loading on 26.2 + Java 25
        // and ended in a SIGSEGV during get_method_id. catsruledogs adds it for every version and launches 26.2 fine.
        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        PUSH_MARGV_LITERAL("--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED");
    }

    // Add Caciocavallo bootclasspath
    // Key fix (26.2 startup crash): the binary caciocavallo switch (aligned with the Ynnyny repo)
    //
    // The workspace wrongly concluded that "the purely Java 17 build SIGSEGVs in get_method_id on Java 25"
    // and introduced a three-way switch with caciocavallo25 (the catsruledogs Java 24 class jar).
    // But the Ynnyny repo launches 26.2 perfectly with the purely Java 17 caciocavallo17 build,
    // showing that diagnosis was wrong. The Java 24 classes in the catsruledogs jar may in fact be the real crash source.
    //
    // Now aligned with Ynnyny: a binary switch
    //   - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，bootclasspath/p）
    //   - Java 17/21/25 -> libs_caciocavallo17 (1.18-SNAPSHOT compiled purely for Java 17, bootclasspath/a)
    const char *cacio_bootclasspath_mode;
    NSString *cacio_libs_path;
    if (isJava8) {
        // Java 8: 1.10-SNAPSHOT, bootclasspath/p (prepended, overriding the java.awt implementation)
        cacio_bootclasspath_mode = "p";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
    } else {
        // Java 17/21/25: 1.18-SNAPSHOT compiled purely for Java 17 (class version 61), bootclasspath/a
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
    }
    NSLog(@"[JavaLauncher] Caciocavallo: isJava8=%d libs=%@ mode=/%s",
          isJava8, cacio_libs_path.lastPathComponent, cacio_bootclasspath_mode);

    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", cacio_bootclasspath_mode];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        // Every cacio jar goes on -Xbootclasspath/a (or /p for Java 8).
        // Following catsruledogs/Amethyst-iOS-25: neither --patch-module nor stub-surface-manager.jar is used.
        // Injecting sun.java2d.SurfaceManagerFactory via --patch-module or a stub jar
        // breaks the java.desktop module encapsulation and causes a get_method_id SIGSEGV.
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    PUSH_MARGV_FORMAT(@"%@", cacio_classpath);

    // stub-surface-manager.jar has been deleted (see the comment above). --patch-module is no longer used.
    // The ClassNotFoundException thrown by CTCPreloadClassLoader.<clinit> is swallowed and does not affect startup.

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        PUSH_MARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            // arg comes from the launchTarget[@"arguments"][@"jvm_processed"] array and is a strong reference,
            // but launchTarget may be released after the loop, so PUSH_MARGV_FORMAT persists it to prevent dangling
            PUSH_MARGV_FORMAT(@"%@", arg);
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // Key fix (26.2 startup crash): a single lwjgl.jar (aligned with the Ynnyny repo)
    // The workspace used to split it into lwjgl.jar and lwjgl33.jar; it now uses one merged jar, as Ynnyny does.
    // The customized root lwjgl.jar (with the iOS-specific LWJGL patches) is already merged into lwjgl.jar by JavaApp/Makefile.
    NSString *lwjglJar = [NSString stringWithFormat:@"%@/lwjgl.jar", librariesPath];
    NSLog(@"[JavaLauncher] Using LWJGL jar at %@", lwjglJar);

    // Check that the target LWJGL jar exists, so it cannot fail silently
    if (![fm fileExistsAtPath:lwjglJar]) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"LWJGL jar missing: %@", [lwjglJar lastPathComponent]]);
        return 1;
    }

    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        // Exclude the merged LWJGL jar precisely to avoid duplicates, while keeping the other dependency jars whose names start with lwjgl
        if ([libFile hasSuffix:@".jar"] &&
            ![libFile isEqualToString:@"lwjgl.jar"]) {
            [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
        }
    }
    [classpathBuilder appendString:lwjglJar];
    NSString *classpath = classpathBuilder;
    if (launchJar) {
        // The JAR goes first on the classpath so that same-named classes in the bundled libs (gson/guava/kotlin-stdlib and so on)
        // do not load first and shadow the installer's own dependencies, causing NoSuchMethodError/LinkageError
        // Under standard `java -jar` semantics the JAR would be the only classpath entry; the bundled libs are kept here only because PojavLauncher
        // and the UIKit bridge classes must load, but the installer's own dependencies take priority
        classpath = [NSString stringWithFormat:@"%@:%@", launchTarget, classpath];
    }
    PUSH_MARGV_LITERAL("-cp");
    PUSH_MARGV_FORMAT(@"%@", classpath);
    PUSH_MARGV_LITERAL("net.kdt.pojavlaunch.PojavLauncher");

    if (launchJar) {
        PUSH_MARGV_LITERAL("-jar");
    } else {
        PUSH_MARGV_FORMAT(@"%@", accountId);
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        PUSH_MARGV_FORMAT(@"%@", launchTarget[@"id"]);
        // Pass the server address to PojavLauncher (FCL style):
        // an empty @"" tells the Java side to append no arguments; a non-empty value is turned by the Java side
        // into --server/--port or --quickPlayMultiplayer depending on the MC version
        NSString *serverIp = [PLProfiles.current serverIpForCurrentProfile] ?: @"";
        PUSH_MARGV_FORMAT(@"%@", serverIp);
    } else {
        PUSH_MARGV_FORMAT(@"%@", launchTarget);
    }
    //PUSH_MARGV_LITERAL("ghidra.GhidraRun");

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}

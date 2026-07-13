#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include "utils.h"

// god knows why Copilot was trying to add this.
#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
// 鬼知道为什么copilot要把这玩意加里头……

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

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

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);

    // 解锁帧率（关闭垂直同步）：读取启动器偏好，通过环境变量传递给 Java 层和 native 桥接层。
    //
    // 帧率解锁的三层机制（各层独立生效，互为兜底）：
    //
    // 1. Java 层（PojavLauncher.java）读取 POJAV_DISABLE_VSYNC=1 后：
    //    a) 强制写 enableVsync=false → MC 不再调用 glfwSwapInterval(1)
    //    b) 强制写 maxFps=260 → MC 1.16+ 源码中 maxFps>=260 视为"无限制"
    //       （之前用 maxFps=0 会被 MC 当作无效值忽略，导致帧率仍被 maxFps=120 限制）
    //
    // 2. native 桥接层（egl_bridge.m pojavSwapInterval）读取 POJAV_DISABLE_VSYNC=1 后：
    //    拦截 MC 的 glfwSwapInterval(1) 请求，强制改为 interval=0
    //    （会记录每次拦截，帮助诊断 mod 运行时重新启用 VSync 的情况）
    //
    // 3. EGL 初始化层（gl_bridge.m gl_make_current）读取 POJAV_DISABLE_VSYNC=1 后：
    //    在 eglMakeCurrent 成功后立即调用 eglSwapInterval(0)。
    //    这是 zink 渲染器帧率解锁的关键——Mesa 21.0 的 zink 在延迟创建 Vulkan swapchain
    //    时根据当前 eglSwapInterval 选择 present mode：
    //      interval=0 → VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超 60）
    //      interval=1 → VK_PRESENT_MODE_FIFO_KHR（等 vsync，锁在屏幕刷新率）
    //    如果等 MC 调用 glfwSwapInterval 时才设置，swapchain 可能已用 FIFO 创建，
    //    Mesa 21.0 的 zink 不会动态重建 swapchain，导致帧率锁死在屏幕刷新率。
    //
    // 关于 MoltenVK 配置：
    //   当前 MoltenVK 版本的 MVKConfiguration 结构体不包含 swapchainPresentMode 成员，
    //   不支持通过配置文件或环境变量强制 present mode。present mode 完全由应用在
    //   vkCreateSwapchainKHR 时选择。设备是否支持 IMMEDIATE present mode 由
    //   MVKPhysicalDeviceMetalFeatures.presentModeImmediate 自动检测（大多数 iOS 设备支持）。
    //
    // 各渲染器的帧率解锁效果：
    // - zink（GL→Vulkan）：通过 eglSwapInterval(0) → IMMEDIATE present mode 完全解锁
    // - Vulkan（LWJGL3）：通过 glfwSwapInterval(0) → IMMEDIATE present mode 完全解锁
    // - ANGLE Metal：eglSwapInterval(0) 让 ANGLE 不等 vsync，渲染线程不阻塞
    // - ProMotion 设备：通过 CADisableMinimumFrameDurationOnPhone + preferredFrameRateRange 启用 120Hz
    setenv("POJAV_DISABLE_VSYNC", getPrefBool(@"video.disable_game_vsync") ? "1" : "0", 1);

    // 帧率解锁诊断日志：记录关键环境变量和偏好设置
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

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    // 关键修复（N3+N4）：retainedCustomFlags 强引用所有自定义 JVM flag 字符串，
    // 防止 [@"-" stringByAppendingString:jvmarg].UTF8String 返回的 C 字符串悬垂。
    //
    // 之前 argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String 直接取临时
    // NSString 的 UTF8String，autoreleased NSString 在 runloop drain 后会释放，
    // 导致 argv 中的指针悬垂。虽然 launchJava 通常在 JVM 启动前不会 drain autoreleasepool，
    // 但这是脆弱的隐式依赖。retainedCustomFlags 作为静态变量，生命周期覆盖整个进程，
    // 保证字符串在 pJLI_Launch 调用期间有效。
    static NSMutableArray<NSString *> *retainedCustomFlags = nil;
    if (retainedCustomFlags == nil) {
        retainedCustomFlags = [NSMutableArray array];
    }
    // 注意：不清空 retainedCustomFlags，因为 launchJava 在进程生命周期内只调用一次。
    // 如果未来变为可多次调用，需要在调用前清空。

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

        // N3 边界检查：argv 数组大小由调用方决定（margv[1000]），这里做防御性检查
        if (*argc + 1 >= 1000) {
            NSLog(@"[JavaLauncher] 警告：margv 已达上限（1000），丢弃自定义 JVM flag：-%@", jvmarg);
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

    BOOL jit26UniversalScript = getPrefBool(@"debug.debug_universal_script_jit");
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if(jit26UniversalScript) {
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"JIT26Script" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]] && !@available(iOS 26.0, *)) {
        NSDebugLog(@"[JavaLauncher] Running in LiveContainer, skipping dyld patch");
    } else if(!@available(iOS 26.0, *) || jit26AlwaysAttached) {
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    } else {
        // iOS 26 上 JIT 更严格，默认不启用 dyld 验证 bypass。
        // 但 MobileGlues / libjnidispatch / JNA 等外部 dylib 若未同团队签名会加载失败，
        // 此处仍尝试 bypass 以保证渲染器与依赖加载，失败则忽略（TXM 模式下可由 entitlement 兜底）。
        @try {
            init_bypassDyldLibValidation();
            NSLog(@"[JavaLauncher] iOS 26: dyld library validation bypass attempted for external dylibs");
        } @catch (NSException *exception) {
            NSLog(@"[JavaLauncher] iOS 26: dyld bypass skipped (%@)", exception.reason);
        }
    }


    init_loadDefaultEnv();
    init_loadCustomEnv();

    // --- [更新] TouchController 通信方式支持 ---
    // 检查是否启用了 TouchController 以及选择的通信方式
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 1) { // UDP 模式
            setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with UDP mode");
        } else if (mode == 2) { // 静态库模式
            // 设置 Unix Domain Socket 路径
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
        // 26.x 官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25），
        // 不再对 preferredJavaVersion 做任何钳制，直接采纳 Profile 指定的 Java 版本。
        // caciocavallo 三路切换会根据实际 Java 版本选择对应 jar（三个独立文件夹）：
        // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT）
        // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译）
        // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，catsruledogs iOS）
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
        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
        // execute_jar 路径（如 OptiFine 安装器）的 caciocavallo 由三路切换自动处理：
        // 实际选中的 Java 运行时是哪个版本，就用对应目录的 caciocavallo jar。
        // 不再在此处对 minVersion 做任何强制提升或钳制。
    }

    // 26.x 版本官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25）。
    // 不再钳制 Profile 的 javaVersion，26.x 必须使用 Java 25 启动。
    // caciocavallo 三路切换（参照 FCL/ZalithLauncher2 二元思路，扩展为三路以兼容 Java 25）：
    // 三个独立的平级文件夹，按实际 Java 版本选择：
    // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，包名 net.java.openjdk.cacio，bootclasspath/p）
    // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    //   来自 catsruledogs/Amethyst-iOS-25。其 CTCGraphicsEnvironment 是 Java 24 class（class version 68），
    //   含 Java 25 兼容修复，纯 Java 17 编译版本会在 get_method_id 阶段 SIGSEGV。
    //   class version 68 仅 Java 24+ 可加载，故 Java 17/21 不能共用，需用 caciocavallo17 目录的纯 Java 17 jar。

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
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        return 1;
    }

    int margc = -1;
    const char *margv[1000];

    // 关键修复（N3+N4）：margv 边界检查 + 字符串生命周期管理
    //
    // N3（边界检查）：
    //   margv[1000] 是固定大小数组，每次 margv[++margc] = ... 都没有检查 margc 是否越界。
    //   如果未来扩展参数可能造成栈缓冲区溢出。这里通过 PUSH_MARGV_* 宏做防御性边界检查。
    //
    // N4（悬垂指针）：
    //   [NSString stringWithFormat:...].UTF8String 返回的 C 字符串指针依赖 autoreleased NSString
    //   的生命周期。当前 launchJVM 函数没有显式 @autoreleasepool 包裹整个函数体，autoreleased
    //   对象进入当前线程的 autorelease pool，到下一次 runloop drain 时才释放。由于函数末尾立即
    //   调用 pJLI_Launch(margc, margv, ...)，期间没有显式 drain，所以暂时安全。
    //   但这是脆弱的隐式依赖：如果将来有人在中间插入 @autoreleasepool 块或调用 drain，
    //   所有 margv 中由 stringWithFormat: 生成的指针会立即悬垂，导致 JVM 启动崩溃。
    //
    //   修复方案：用 retainedStrings 数组强引用所有通过 stringWithFormat: 创建的 NSString，
    //   确保其生命周期覆盖 pJLI_Launch 调用。retainedStrings 是局部 strong 引用，随函数
    //   退出自动释放，无需手动管理。
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    // 宏：安全地添加一个字面量参数到 margv
    // 字符串字面量（如 "-XstartOnFirstThread"）是静态存储期的 const char*，永不失效
    // 边界检查：margc 达到上限时停止添加，避免栈溢出
    #define PUSH_MARGV_LITERAL(literal) do { \
        if (margc + 1 < 1000) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] 警告：margv 已达上限（1000），丢弃字面量参数 %s", (literal)); \
        } \
    } while (0)

    // 宏：通过 stringWithFormat: 构造参数并添加到 margv
    // 创建的 NSString 会被 retainedStrings 强引用，直到函数返回才释放，
    // 保证 margv 中保存的 UTF8String 指针在 pJLI_Launch 调用期间有效。
    // 注意：NSLog 警告消息不直接用 fmt 作为格式串（避免 % 被错误解析），仅打印字面量提示。
    #define PUSH_MARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 1000) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] 警告：margv 已达上限（1000），丢弃格式化参数"); \
        } \
    } while (0)

    PUSH_MARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_MARGV_LITERAL("-XstartOnFirstThread");
    if (!launchJar) {
        PUSH_MARGV_LITERAL("-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader");
    }
    PUSH_MARGV_LITERAL("-Xms128M");
    PUSH_MARGV_FORMAT(@"-Xmx%dM", allocmem);
    // Detect LWJGL version early to set correct library path
    // 参照 Taylen-chud/Amethyst-iOS（Rebase-everything）的 dylib 布局：
    //   Frameworks/              = 共享 dylib（libMoltenVK/libopenal/libOSMesa/libgl4es/libglapi/libvirgil_test_server/libspirv-cross-c-shared.0）
    //   Frameworks/lwjgl33/      = LWJGL 3.3.3 专属 dylib（liblwjgl/liblwjgl_opengl/liblwjgl_nanovg/liblwjgl_stb/liblwjgl_tinyfd/liblwjgl_vma/libshaderc/libfreetype 等 9 个）
    //   Frameworks/lwjgl34/      = LWJGL 3.4.x 专属 dylib（liblwjgl/liblwjgl_opengl/liblwjgl_msdfgen/liblwjgl_nanovg/liblwjgl_stb/liblwjgl_tinyfd/liblwjgl_vma/libshaderc/libfreetype 共 9 个）
    // library.path = Frameworks:Frameworks/lwjglXX（共享在前，LWJGL 专属在后）
    //
    // 关于 libglfw.dylib：iOS 上不需要独立 libglfw.dylib。workspace 用 Java + native 桥接
    // （pojav* 函数）完全替代 GLFW native 库。JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java 是
    // override 版本，加载主程序二进制 AngelAuraAmethyst（System.load(BUNDLE_PATH/AngelAuraAmethyst)），
    // 所有函数指针从 pojav* 符号解析，不查找任何 glfw 原生符号。因此 libglfw.dylib 是多余文件，
    // 已从 lwjgl34/ 删除。
    //
    // 关于 libspirv-cross-c-shared.0.dylib：作为共享 dylib 放在根目录 Frameworks/。
    // LWJGL spvc 模块通过 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0 显式指定库名，
    // LWJGL 加载 libspirv-cross-c-shared.0.dylib，从 library.path 的 Frameworks/ 找到。
    // spirv-cross 是外部库（非 LWJGL 专属），LWJGL 3.3.x 和 3.4.x 共用同一版本，放根目录合理。
    //
    // 之前根目录 Frameworks/ 同时放置 LWJGL 3.4.x 专属 dylib，26.x 路径为 Frameworks:Frameworks，
    // 虽能工作但与 Taylen-chud 结构不一致，且旧版路径 Frameworks/lwjgl33:Frameworks 可能误从根目录
    // 加载到 LWJGL 3.4.x 的 liblwjgl.dylib 造成版本错配。现对齐 Taylen-chud：专属 dylib 全部移入
    // lwjgl34/，根目录只保留共享 dylib（含 spirv-cross），旧版与新版都走 Frameworks:Frameworks/lwjglXX 路径。
    BOOL useLWJGL33 = NO;
    BOOL foundLWJGLDeclaration = NO;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        NSArray *libraries = launchTarget[@"libraries"];
        for (NSDictionary *lib in libraries) {
            NSString *name = lib[@"name"];
            if (name && [name hasPrefix:@"org.lwjgl:lwjgl:"]) {
                foundLWJGLDeclaration = YES;
                NSString *ver = [[name componentsSeparatedByString:@":"] lastObject];
                NSArray *parts = [ver componentsSeparatedByString:@"."];
                if (parts.count >= 2 && [[parts objectAtIndex:1] intValue] < 4) {
                    useLWJGL33 = YES;
                }
                break;
            }
        }
        // Minecraft 26.x 版本 JSON 不再声明 LWJGL，但需要使用 3.4.x（含 spvc/vma/shaderc/msdfgen）。
        // 若未扫描到 LWJGL 声明且所需 Java >= 21，判定为 26.x，强制使用 LWJGL 3.4.x 路径。
        // 26.2 官方强制 Java 25（Profile javaVersion=25），minVersion 经 preferredJavaVersion
        // 覆盖后为 25，此处 minVersion >= 21 条件仍成立，LWJGL 3.4.x 路径正确选中。
        if (!foundLWJGLDeclaration && minVersion >= 21) {
            useLWJGL33 = NO;
            NSLog(@"[JavaLauncher] 26.x detected (no LWJGL declaration, minJava=%d), defaulting to LWJGL 3.4.x", minVersion);
        }
    }
    NSString *frameworksPath = [NSString stringWithFormat:@"%@/Frameworks", NSBundle.mainBundle.bundlePath];
    // 26.x（LWJGL 3.4.x）走 lwjgl34/，旧版走 lwjgl33/。共享 dylib 始终从根目录 Frameworks/ 加载。
    NSString *lwjglNativesSubfolder = useLWJGL33 ? @"lwjgl33" : @"lwjgl34";
    NSString *lwjglFrameworksPath = [frameworksPath stringByAppendingPathComponent:lwjglNativesSubfolder];
    PUSH_MARGV_FORMAT(@"-Djava.library.path=%@:%@", frameworksPath, lwjglFrameworksPath);
    NSLog(@"[JavaLauncher] library.path = %@:%@ (useLWJGL33=%d)", frameworksPath, lwjglFrameworksPath, useLWJGL33);
    PUSH_MARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_MARGV_FORMAT(@"-Duser.home=%s", getenv("POJAV_HOME"));
    PUSH_MARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_MARGV_FORMAT(@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);
    PUSH_MARGV_LITERAL("-Dorg.lwjgl.glfw.checkThread0=false");
    PUSH_MARGV_LITERAL("-Dorg.lwjgl.system.allocator=system");
    //PUSH_MARGV_LITERAL("-Dorg.lwjgl.util.NoChecks=true");
    PUSH_MARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");

    // ============================================================================
    // ZeroTier 联机 SOCKS5 代理注入
    // ============================================================================
    // 当用户在联机界面连接到 ZeroTier 房间后，MultiplayerManager 会启动一个本地
    // SOCKS5 代理（127.0.0.1:1080），并通过环境变量 AMETHYST_SOCKS5_PROXY 传递
    // 代理地址（格式："127.0.0.1:port"）。
    //
    // 这里检测该环境变量，如果存在，则注入 JVM 的 SOCKS5 代理参数：
    //   -DsocksProxyHost=127.0.0.1
    //   -DsocksProxyPort=<port>
    //
    // Java 的 Socket 网络栈会自动走 SOCKS5 代理，所有 Minecraft 的 TCP 流量
    // （包括登录、世界加载、区块同步、聊天等）都会经过本地 SOCKS5 代理，再由
    // SOCKS5Proxy 通过 libzt 的 BSD socket API 转发到 ZeroTier 虚拟网络中，
    // 最终到达房主的 Minecraft 服务器。
    //
    // 参照 FCL (FoldCraftLauncher) 和 ZL2 (ZalithLauncher) 的实现：
    //   - FCL 在 LaunchPlugin 中注入 socksProxyHost/socksProxyPort 参数
    //   - ZL2 在 ZTLaunchPlugin 中做相同的事情
    //   - 本实现直接在 JVM 参数构建阶段注入，效果一致
    //
    // 注意：
    //   1. 仅当 AMETHYST_SOCKS5_PROXY 环境变量存在且格式正确时才注入
    //   2. 不影响非联机场景下的正常网络访问（环境变量不存在时跳过）
    //   3. 此参数对 Java 的所有 Socket 连接生效，包括第三方库的网络请求
    // ============================================================================
    const char *socks5ProxyEnv = getenv("AMETHYST_SOCKS5_PROXY");
    if (socks5ProxyEnv && socks5ProxyEnv[0] != '\0') {
        NSString *proxyStr = [NSString stringWithUTF8String:socks5ProxyEnv];
        // 解析 "host:port" 格式
        NSRange colonRange = [proxyStr rangeOfString:@":"];
        if (colonRange.location != NSNotFound && colonRange.location > 0 &&
            colonRange.location + 1 < proxyStr.length) {
            NSString *proxyHost = [proxyStr substringToIndex:colonRange.location];
            NSString *proxyPortStr = [proxyStr substringFromIndex:colonRange.location + 1];

            // 校验端口为纯数字且在有效范围
            NSInteger portValue = [proxyPortStr integerValue];
            if (portValue > 0 && portValue <= 65535) {
                PUSH_MARGV_FORMAT(@"-DsocksProxyHost=%@", proxyHost);
                PUSH_MARGV_FORMAT(@"-DsocksProxyPort=%@", proxyPortStr);

                // 关键修复（C4/H13）：注入 -DsocksNonProxyHosts 参数，让 Minecraft 登录、
                // 认证、皮肤、披风、版本库、Mod 下载等官方/第三方服务请求绕过 SOCKS5 代理。
                //
                // 问题描述：
                //   仅注入 socksProxyHost/socksProxyPort 后，Java 的所有 Socket 连接默认都会
                //   走 SOCKS5 代理，包括 Microsoft 登录、Mojang 认证、Yggdrasil 验证、
                //   皮肤/披风资源加载、Mojang 版本库元数据、Modrinth/CurseForge Mod 下载、
                //   GitHub 资源下载、AWS S3 资源下载等。这些服务走 ZeroTier 虚拟网络会被
                //   路由到错误的目标，导致登录失败、皮肤丢失、Mod 无法下载，进而影响联机体验。
                //
                // 修复方案：
                //   通过 socksNonProxyHosts JVM 参数指定不走代理的主机名模式列表，
                //   多个模式用 "|" 分隔，支持 * 通配符（如 *.mojang.com）。
                //
                // 主机名列表说明：
                //   - localhost / 127.* / [::1]：本地回环，绝不应走代理
                //   - *.minecraft.net：Minecraft 官方服务（会话、会话服务器、皮肤服务）
                //   - *.mojang.com：Mojang 服务（认证、皮肤、披风、版本库）
                //   - *.microsoft.com：Microsoft 在线服务（账号、Xbox Live 元数据）
                //   - *.microsoftonline.com：Microsoft 在线认证
                //   - *.xboxlive.com：Xbox Live 认证（Mojang 与 MS 账号互通）
                //   - *.modrinth.com：Modrinth Mod 下载
                //   - *.curseforge.com：CurseForge Mod 下载
                //   - *.githubusercontent.com：GitHub 资源（部分 Mod/资源/raw 文件）
                //   - *.github.com：GitHub API
                //   - *.amazonaws.com：AWS S3（Mojang/MS 资源、皮肤 CDN）
                //   - *.cloudfront.net：CloudFront（部分资源 CDN）
                //   - *.akamaihd.net：Akamai（部分资源 CDN）
                //   - 10.* / 192.168.* / 172.16-31.*：本地局域网，绝不应走代理
                //     注意：10.* 与 ZeroTier 默认子网 10.147.17.x 重叠，但我们用 SOCKS5
                //     而非系统路由，因此本地 10.* 仍走系统路由。Minecraft 房主的
                //     ZeroTier IP 是通过 SOCKS5 转发的，不会受 socksNonProxyHosts 影响。
                //
                // 重要：房主在 ZeroTier 网络中的 IP（如 10.147.17.x）走 SOCKS5 代理时是
                // 直接通过 ZeroTierBridge 的 libzt socket 转发到 ZeroTier 网络的，
                // 不依赖 socksNonProxyHosts 的设置，所以即使 10.* 在不代理列表里，
                // Minecraft 仍能正确连接房主服务器。
                NSString *nonProxyHosts = @"localhost|127.*|[::1]|"
                                          @"*.minecraft.net|*.mojang.com|"
                                          @"*.microsoft.com|*.microsoftonline.com|"
                                          @"*.xboxlive.com|*.modrinth.com|"
                                          @"*.curseforge.com|*.githubusercontent.com|"
                                          @"*.github.com|*.amazonaws.com|"
                                          @"*.cloudfront.net|*.akamaihd.net|"
                                          @"10.*|192.168.*|172.16.*|172.17.*|172.18.*|"
                                          @"172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|"
                                          @"172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|"
                                          @"172.29.*|172.30.*|172.31.*";
                PUSH_MARGV_FORMAT(@"-DsocksNonProxyHosts=%@", nonProxyHosts);

                NSLog(@"[JavaLauncher] 已注入 ZeroTier SOCKS5 代理：%@:%@（同时注入 socksNonProxyHosts 让登录/皮肤/Mod 下载绕过代理）",
                      proxyHost, proxyPortStr);
            } else {
                NSLog(@"[JavaLauncher] AMETHYST_SOCKS5_PROXY 端口无效：%@", proxyPortStr);
            }
        } else {
            NSLog(@"[JavaLauncher] AMETHYST_SOCKS5_PROXY 格式无效（应为 host:port）：%@", proxyStr);
        }
    }

    // Preset OpenGL libname
    const char *glLibName = getenv("AMETHYST_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // 自动选择渲染器：基于 MC 所需 Java 版本推断。
            // README 宣传 "Auto 自动选择合适的渲染器（含 MobileGlues）"，原代码无版本判断永远选 ANGLE。
            // - Java 8 (MC 1.16.5-) 走 gl4es，对旧版 GL 兼容性最佳
            // - Java 17 (MC 1.17-1.20.4) 走 ANGLE（GL 3.2 Core）
            // - Java 21+ (MC 1.20.5+/26.x) 优先走 MobileGlues（GL 4.x），缺失则回退 ANGLE
            NSString *mobilegluesPath = [NSString stringWithFormat:@"%@/Frameworks/%s",
                NSBundle.mainBundle.bundlePath, RENDERER_NAME_MOBILEGLUES];
            if (minVersion >= 21 && [NSFileManager.defaultManager fileExistsAtPath:mobilegluesPath]) {
                glLibName = RENDERER_NAME_MOBILEGLUES;
            } else if (minVersion >= 17) {
                glLibName = RENDERER_NAME_MTL_ANGLE;
            } else {
                glLibName = RENDERER_NAME_GL4ES;
            }
            // 同步更新环境变量，使 egl_bridge 选用对应桥接
            setenv("AMETHYST_RENDERER", glLibName, 1);
            NSLog(@"[JavaLauncher] Auto renderer resolved to %s (minJava=%d)", glLibName, minVersion);
        }
        if (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0) {
            // Vulkan mode: set vulkan libname and fallback opengl libname for LWJGL startup probing
            PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.vulkan.libname=%s", RENDERER_NAME_VULKAN);
            // 参照 TAYlen-chud/Amethyst-iOS: Vulkan 模式下 OpenGL 回退库使用 MobileGlues 而非 ANGLE
            // 原因：MC 26.2 的 NativeLibrariesBootstrap.loadOpenGL() 在启动时会初始化 GL，
            // iOS 上无系统 OpenGL framework，ANGLE 可能不如 MobileGlues 适合
            // （MobileGlues 可路由到 Vulkan 后端，与 Vulkan 模式更协同）
            // 仅当 MobileGlues 存在时使用，否则回退 ANGLE
            NSString *mobilegluesVulkanPath = [NSString stringWithFormat:@"%@/Frameworks/%s",
                NSBundle.mainBundle.bundlePath, RENDERER_NAME_MOBILEGLUES];
            if ([NSFileManager.defaultManager fileExistsAtPath:mobilegluesVulkanPath]) {
                glLibName = RENDERER_NAME_MOBILEGLUES;
            } else {
                glLibName = RENDERER_NAME_MTL_ANGLE;
            }
        }
        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", glLibName);

        // 显式指定 spirv-cross 库名（参照 catsruledogs/Amethyst-iOS-25）：
        // LWJGL spvc 模块默认查找 "spirv-cross" -> 加载 libspirv-cross.dylib（macOS 标准名），
        // 但实际文件名为 libspirv-cross-c-shared.0.dylib（带版本后缀的 SO 名）。
        // 显式设置 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0，LWJGL 的 Library.loadNative
        // 会对 libname 加 "lib" 前缀和 ".dylib" 后缀，得到 "libspirv-cross-c-shared.0.dylib"，
        // 从 library.path（Frameworks:Frameworks/lwjglXX）的根目录 Frameworks/ 找到该文件。
        //
        // 为什么不用 Makefile 软链接（libspirv-cross.dylib -> libspirv-cross-c-shared.0.dylib）+默认名：
        // 之前曾尝试该方案，但 26.2 启动时在 "Now starting game" 阶段 SIGSEGV at get_method_id。
        // 根因：LWJGL spvc 模块在 native 库加载失败或 JNI 注册状态不一致时，get_method_id 可能
        // 访问已损坏的类元数据导致 SIGSEGV（而非抛出 UnsatisfiedLinkError）。软链接方案依赖构建
        // 阶段正确创建符号链接，一旦构建环境差异导致软链接缺失或指向错误，spvc 加载会进入异常
        // 状态。显式指定完整 SO 名（spirv-cross-c-shared.0）直接定位实际文件，无需软链接，
        // 与 catsruledogs（能正常启动 26.2 + Java 25）完全一致，是最稳妥的方案。
        //
        // LWJGL Library.loadNative 的 libname 处理（macOS）：
        // - 若 libname 已含 "lib" 前缀和 ".dylib" 后缀，直接使用
        // - 否则加 "lib" 前缀和 ".dylib" 后缀
        // "spirv-cross-c-shared.0" -> "libspirv-cross-c-shared.0.dylib"（正确，不会二次包装）
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0");
    }

      // 添加authlib-injector参数以支持第三方认证账户的皮肤显示
    if ([accountId length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    // arg 来自 authlibArgs 数组，是 strong 引用；但数组本身可能在循环外
                    // 被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
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
    // 提前计算 isJava25，供下方 add-exports 条件判断与 cacio bootclasspath 三路切换共用
    BOOL isJava25 = (minVersion >= 25) || [javaHome containsString:@"java-25"];
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
        // 启用 native access（Java 17+ 支持，Java 25 强制要求）。
        // 参照 catsruledogs/Amethyst-iOS-25：Java 25 对受限方法（@Restricted，含 JNI、
        // sun.misc.Unsafe、Foreign API）的限制更严格，缺失此参数会导致 caciocavallo/LWJGL/JNA
        // 的 native access 触发警告路径，在 bootclasspath/a 未命名模块类上可能引发
        // get_method_id 访问不一致的类元数据导致 SIGSEGV（26.2 启动崩溃的根因）。
        // 日志中 "WARNING: Use --enable-native-access=ALL-UNNAMED to avoid a warning"
        // 也明确提示需要此参数。Java 17/21 添加此参数无副作用，统一在非 Java 8 分支添加。
        PUSH_MARGV_LITERAL("--enable-native-access=ALL-UNNAMED");

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
        // 参照 catsruledogs/Amethyst-iOS-25：不添加 sun.awt / sun.awt.image / java.awt.peer 的
        // add-opens。catsruledogs 不加这些 opens 也能正常启动 26.2 + Java 25。
        // workspace 之前多加这 3 条 opens 会导致 Java 25 上 GE 提前初始化，
        // 在 caciocavallo25 的 CTCGraphicsEnvironment 注册完成前触发 get_method_id → SIGSEGV。
        // 纯 Java 17 编译版 caciocavallo17（Java 17/21 用）不依赖这些 opens，
        // 其 CTCGraphicsEnvironment 通过 --add-exports（上方已添加）即可访问所需内部 API。

        // cpw.mods.bootstraplauncher 模块导出：所有 Java 版本均添加（参照 catsruledogs/Amethyst-iOS-25）。
        // 之前仅对 Java 17/21 添加、Java 25 跳过，导致 26.2 + Java 25 启动时类加载混乱，
        // 最终在 get_method_id 阶段 SIGSEGV。catsruledogs 对所有版本统一添加此导出且能正常启动 26.2。
        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        PUSH_MARGV_LITERAL("--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED");
    }

    // Add Caciocavallo bootclasspath
    // caciocavallo 三路切换（参照 FCL/ZalithLauncher2 的二元思路，扩展为三路以兼容 Java 25）：
    // 三个独立的 caciocavallo 文件夹，按实际选中的 Java 运行时版本选择：
    //   - isJava8 通过 libjli 路径检测（lib/jli/libjli.dylib 仅 Java 8 存在）
    //   - isJava25 通过 javaHome 路径包含 "java-25" 或 minVersion >= 25 检测
    //   - 其余为 Java 17/21
    //
    // 目录布局（三个平级独立文件夹，无嵌套子目录）：
    //   libs_caciocavallo   → Java 8（1.10-SNAPSHOT，包名 net.java.openjdk.cacio，class version 52）
    //   libs_caciocavallo17 → Java 17/21（1.18-SNAPSHOT 纯 Java 17 编译，包名 com.github.caciocavallosilano.cacio，class version 61）
    //   libs_caciocavallo25 → Java 25（1.18-SNAPSHOT 含 Java 24 class，包名 com.github.caciocavallosilano.cacio，来自 catsruledogs iOS）
    //
    // 为什么不能像 FCL/ZL2 那样简单二元切换（Java 8 vs Java 17+）：
    //   catsruledogs/Amethyst-iOS-25 的 caciocavallo25 jar 中，AWT 入口类
    //   CTCGraphicsEnvironment（通过 -Djava.awt.graphicsenv 在 JVM 启动时加载）
    //   是 Java 24 编译（class version 68），Java 17/21 无法加载。
    //   而 26.2 + Java 25 又必须用这个 jar（含 Java 25 兼容修复，纯 Java 17 编译版本
    //   会在 get_method_id 阶段 SIGSEGV）。
    //   因此 Java 17/21 必须用纯 Java 17 编译的 jar（class version 61，放 caciocavallo17），
    //   Java 25 必须用 catsruledogs 的 jar（含 Java 24 class，放 caciocavallo25），两者不可共用。
    //   这是确保"所有版本（Java 8/17/21/25）启动都没有问题"的唯一方案。
    // isJava25 已在上方提前计算（供 add-exports 条件判断与 bootclasspath 切换共用）
    const char *cacio_bootclasspath_mode;
    NSString *cacio_libs_path;
    if (isJava8) {
        // Java 8: 1.10-SNAPSHOT，bootclasspath/p（前置，覆盖 java.awt 实现）
        cacio_bootclasspath_mode = "p";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
    } else if (isJava25) {
        // Java 25: 1.18-SNAPSHOT 含 Java 24 class（catsruledogs iOS），bootclasspath/a
        // 注意：caciocavallo25 的 cacio-tta jar 与 catsruledogs/Amethyst-iOS-25 的
        // libs_caciocavallo17/cacio-tta jar MD5 完全一致（catsruledogs 对 Java 25 也用
        // caciocavallo17 目录，workspace 为区分 Java 17/21 纯编译版另设 caciocavallo25）。
        //
        // 关于 stub-surface-manager.jar：已删除，不再使用。
        // CTCPreloadClassLoader.<clinit> 会 Class.forName("sun.java2d.SurfaceManagerFactory")，
        // Java 9+ 已将该类迁至 sun.awt.image.SurfaceManagerFactory，故 forName 抛
        // ClassNotFoundException。但该 <clinit> 用 try/catch(Exception) 包裹整个逻辑
        // （异常表 16-177），异常仅 printStackTrace 后被吞掉，不终止启动。
        // catsruledogs 不提供 stub 也能正常启动 26.2 + Java 25，证明此异常无害。
        // 之前 workspace 添加 stub-surface-manager.jar（含 sun/java2d/SurfaceManagerFactory）
        // 到 bootclasspath/a，反而把类注入 java.desktop 模块内部包，破坏模块封装，
        // 导致后续 JNI get_method_id 时类查找状态损坏 → SIGSEGV。删除 stub 后对齐
        // catsruledogs，问题解决。
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo25", NSBundle.mainBundle.bundlePath];
    } else {
        // Java 17/21: 1.18-SNAPSHOT 纯 Java 17 编译（class version 61），bootclasspath/a
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
    }
    NSLog(@"[JavaLauncher] Caciocavallo: isJava8=%d isJava25=%d libs=%@ mode=/%s",
          isJava8, isJava25, cacio_libs_path.lastPathComponent, cacio_bootclasspath_mode);

    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", cacio_bootclasspath_mode];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        // 所有 cacio jar 均放入 -Xbootclasspath/a（或 /p for Java 8）。
        // 参照 catsruledogs/Amethyst-iOS-25：不使用 --patch-module，不使用 stub-surface-manager.jar。
        // 之前用 --patch-module 或 stub jar 注入 sun.java2d.SurfaceManagerFactory，
        // 会破坏 java.desktop 模块封装，导致 get_method_id SIGSEGV。
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    PUSH_MARGV_FORMAT(@"%@", cacio_classpath);

    // stub-surface-manager.jar 已删除（见上方注释）。不再使用 --patch-module。
    // CTCPreloadClassLoader.<clinit> 抛出的 ClassNotFoundException 被吞掉，不影响启动。

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        PUSH_MARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            // arg 来自 launchTarget[@"arguments"][@"jvm_processed"] 数组，是 strong 引用；
            // 但 launchTarget 可能在循环结束后被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
            PUSH_MARGV_FORMAT(@"%@", arg);
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // Pick correct LWJGL jar based on earlier version detection
    NSString *lwjglJar = useLWJGL33
        ? [NSString stringWithFormat:@"%@/lwjgl33.jar", librariesPath]
        : [NSString stringWithFormat:@"%@/lwjgl.jar", librariesPath];
    NSLog(@"[JavaLauncher] Using LWJGL %@ jar at %@", useLWJGL33 ? @"3.3.x" : @"3.4.x", lwjglJar);

    // 校验目标 LWJGL jar 是否存在，避免静默崩溃
    if (![fm fileExistsAtPath:lwjglJar]) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"LWJGL jar missing: %@", [lwjglJar lastPathComponent]]);
        return 1;
    }

    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        // 精确排除合并后的 LWJGL jar，避免重复；保留其他以 lwjgl 开头的依赖 jar
        if ([libFile hasSuffix:@".jar"] &&
            ![libFile isEqualToString:@"lwjgl.jar"] &&
            ![libFile isEqualToString:@"lwjgl33.jar"]) {
            [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
        }
    }
    [classpathBuilder appendString:lwjglJar];
    NSString *classpath = classpathBuilder;
    if (launchJar) {
        // JAR 放在 classpath 最前面，避免 bundle libs 中的同名类（gson/guava/kotlin-stdlib 等）
        // 优先加载，导致 installer 自带依赖被遮蔽引发 NoSuchMethodError/LinkageError
        // 标准 `java -jar` 语义下 JAR 本应是唯一 classpath，此处保留 bundle libs 仅因 PojavLauncher
        // 与 UIKit bridge 类需要加载，但 installer 自身依赖应优先
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
        // 传递服务器地址给 PojavLauncher（FCL 风格）：
        // 留空传 @"", Java 端据此判断不追加任何参数；非空则由 Java 端按 MC 版本
        // 解析为 --server/--port 或 --quickPlayMultiplayer
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

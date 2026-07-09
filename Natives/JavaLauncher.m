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

    // Force MoltenVK to use immediate present mode (uncapped fps)
    setenv("MVK_CONFIG_PRESENT_MODE_IMMEDIATE", "1", 1);
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

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
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
        // caciocavallo 三路切换会根据实际 Java 版本选择对应 jar：
        // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT）
        // - Java 17/21 → libs_caciocavallo/java17（1.18-SNAPSHOT 纯 Java 17 编译）
        // - Java 25    → libs_caciocavallo17（1.18-SNAPSHOT 含 Java 24 class，catsruledogs iOS）
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
    // caciocavallo 切换（参照 FCL/ZalithLauncher2 二元思路，扩展为三路以兼容 Java 25）：
    // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，包名 net.java.openjdk.cacio，bootclasspath/p）
    // - Java 17/21 → libs_caciocavallo/java17（1.18-SNAPSHOT 纯 Java 17 编译，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    // - Java 25    → libs_caciocavallo17（1.18-SNAPSHOT 含 Java 24 class，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    //   来自 catsruledogs/Amethyst-iOS-25。其 CTCGraphicsEnvironment 是 Java 24 class（class version 68），
    //   含 Java 25 兼容修复，纯 Java 17 编译版本会在 get_method_id 阶段 SIGSEGV。
    //   class version 68 仅 Java 24+ 可加载，故 Java 17/21 不能共用，需用 java17/ 目录的纯 Java 17 jar。

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

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    // Detect LWJGL version early to set correct library path
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
        // Minecraft 26.x 版本 JSON 不再声明 LWJGL，但需要使用 3.4.x（含 spvc/vma/shaderc）。
        // 若未扫描到 LWJGL 声明且所需 Java >= 21，判定为 26.x，强制使用 LWJGL 3.4.x 路径。
        // 26.2 官方强制 Java 25（Profile javaVersion=25），minVersion 经 preferredJavaVersion
        // 覆盖后为 25，此处 minVersion >= 21 条件仍成立，LWJGL 3.4.x 路径正确选中。
        if (!foundLWJGLDeclaration && minVersion >= 21) {
            useLWJGL33 = NO;
            NSLog(@"[JavaLauncher] 26.x detected (no LWJGL declaration, minJava=%d), defaulting to LWJGL 3.4.x", minVersion);
        }
    }
    NSString *frameworksPath = [NSString stringWithFormat:@"%@/Frameworks", NSBundle.mainBundle.bundlePath];
    NSString *lwjglFrameworksPath = useLWJGL33
        ? [frameworksPath stringByAppendingPathComponent:@"lwjgl33"]
        : frameworksPath;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@:%@", lwjglFrameworksPath, frameworksPath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    //margv[++margc] = "-Dorg.lwjgl.util.NoChecks=true";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";

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
            margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.vulkan.libname=%s", RENDERER_NAME_VULKAN].UTF8String;
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
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;

        // 参照 TAYlen-chud/Amethyst-iOS: 显式指定 spirv-cross 库名
        // 原因：LWJGL 3.4.x（MC 1.20.5+ / 26.x 使用）默认尝试加载 libspirv-cross.dylib，
        // 但 MobileGlues 已加载 libspirv-cross-c-shared.0.dylib，两者 install_name 不同
        // 会导致 dyld install_name 冲突或 spirv-cross 重复注册
        // 显式指定 libname 为 spirv-cross-c-shared.0 可避免此问题
        // 对 Java 8 / 1.21 及以下版本（使用 LWJGL 3.3.x）无影响，该参数会被忽略
        margv[++margc] = "-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0";
    }

      // 添加authlib-injector参数以支持第三方认证账户的皮肤显示
    if ([username length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    margv[++margc] = arg.UTF8String;
                    NSLog(@"[JavaLauncher] Added authlib-injector arg: %s", arg.UTF8String);
                }     
            } else {
                NSLog(@"[JavaLauncher] Warning: No authlib-injector arguments available");
            }
        }
    }
  
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }
    if(getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchsvc.jar=", librariesPath].UTF8String;
    }

    // Workaround random stack guard allocation crashes
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        margv[++margc] = "-XX:+MirrorMappedCodeCache";
    }

    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
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
    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Required by Cosmetica to inject DNS
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

        // Required by Caciocavallo17 to access internal API
        margv[++margc] = "--add-exports=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.base/sun.security.action=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.util=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED";
        // Caciocavallo17 的 CTCGraphicsEnvironment 通过反射访问 sun.awt.PlatformGraphicsInfo
        // 和 sun.awt.image，若缺少这些 opens，GE 初始化失败会导致 JVM 回退到 headless 模式，
        // OptiFine 安装器等 Swing GUI 应用抛出 HeadlessException。
        // 这些 add-opens 在 Java 17/21/25 上都需要，对 Java 17/21 是必需的，
        // 对 Java 25 也无害（多余的 opens 会被 JVM 忽略）。
        margv[++margc] = "--add-opens=java.desktop/sun.awt=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.awt.image=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/java.awt.peer=ALL-UNNAMED";

        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
    }

    // Add Caciocavallo bootclasspath
    // caciocavallo 切换（参照 FCL/ZalithLauncher2 的二元思路，扩展为三路以兼容 Java 25）：
    // 切换依据为实际选中的 Java 运行时版本：
    //   - isJava8 通过 libjli 路径检测（lib/jli/libjli.dylib 仅 Java 8 存在）
    //   - isJava25 通过 javaHome 路径包含 "java-25" 或 minVersion >= 25 检测
    //   - 其余为 Java 17/21
    //
    // 为什么不能像 FCL/ZL2 那样简单二元切换（Java 8 vs Java 17+）：
    //   catsruledogs/Amethyst-iOS-25 的 caciocavallo17 jar 中，AWT 入口类
    //   CTCGraphicsEnvironment（通过 -Djava.awt.graphicsenv 在 JVM 启动时加载）
    //   是 Java 24 编译（class version 68），Java 17/21 无法加载。
    //   而 26.2 + Java 25 又必须用这个 jar（含 Java 25 兼容修复，纯 Java 17 编译版本
    //   会在 get_method_id 阶段 SIGSEGV）。
    //   因此 Java 17/21 必须用纯 Java 17 编译的 jar（class version 61），
    //   Java 25 必须用 catsruledogs 的 jar（含 Java 24 class），两者不可共用。
    //   这是确保"所有版本（Java 8/17/21/25）启动都没有问题"的唯一方案。
    BOOL isJava25 = (minVersion >= 25) || [javaHome containsString:@"java-25"];
    const char *cacio_bootclasspath_mode;
    NSString *cacio_libs_path;
    NSString *cacio_stub_jar_path;
    if (isJava8) {
        // Java 8: 1.10-SNAPSHOT，bootclasspath/p（前置，覆盖 java.awt 实现）
        cacio_bootclasspath_mode = "p";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
        cacio_stub_jar_path = nil; // Java 8 不需要 stub-surface-manager
    } else if (isJava25) {
        // Java 25: 1.18-SNAPSHOT 含 Java 24 class（catsruledogs iOS），bootclasspath/a
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
        cacio_stub_jar_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17/stub-surface-manager.jar", NSBundle.mainBundle.bundlePath];
    } else {
        // Java 17/21: 1.18-SNAPSHOT 纯 Java 17 编译（class version 61），bootclasspath/a
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo/java17", NSBundle.mainBundle.bundlePath];
        cacio_bootclasspath_mode = "a";
        cacio_stub_jar_path = [NSString stringWithFormat:@"%@/libs_caciocavallo/java17/stub-surface-manager.jar", NSBundle.mainBundle.bundlePath];
    }
    NSLog(@"[JavaLauncher] Caciocavallo: isJava8=%d isJava25=%d libs=%@ mode=/%s",
          isJava8, isJava25, cacio_libs_path.lastPathComponent, cacio_bootclasspath_mode);

    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", cacio_bootclasspath_mode];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        // 跳过 stub-surface-manager.jar：它通过 --patch-module java.desktop 注入，
        // 不能放在 -Xbootclasspath/a（unnamed module），否则与 java.desktop 模块的
        // sun.java2d 包形成 split package，Java 9+ 会拒绝加载。
        // hasSuffix:@".jar" 会自动跳过子目录（如 java17/）。
        if ([file hasSuffix:@".jar"] && ![file isEqualToString:@"stub-surface-manager.jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    // Java 9+ 移除了 sun.java2d.SurfaceManagerFactory（迁至 sun.awt.image.SurfaceManagerFactory）。
    // Caciocavallo17 的 CTCPreloadClassLoader.<clinit> 仍调用 Class.forName("sun.java2d.SurfaceManagerFactory")
    // 来重置其 instance 字段。forName 失败抛出 ClassNotFoundException 后，<clinit> 的 catch 块会
    // 跳过后面的 setFinalStatic(LocalGE.INSTANCE, new CTCGraphicsEnvironment())，导致 GE 未安装，
    // JVM 回退 headless 模式，Swing GUI（如 OptiFine 安装器）抛出 java.awt.HeadlessException。
    // sun.java2d 包属于 java.desktop 模块，通过 --patch-module 注入 stub 类让 forName 成功，
    // <clinit> 才能继续安装 CTCGraphicsEnvironment，execute_jar 与 Minecraft 启动均受益。
    // stub jar 路径随切换变化：Java 25 从 caciocavallo17/ 加载，Java 17/21 从 caciocavallo/java17/ 加载。
    if (cacio_stub_jar_path) {
        if ([fm fileExistsAtPath:cacio_stub_jar_path]) {
            margv[++margc] = [NSString stringWithFormat:@"--patch-module=java.desktop=%@", cacio_stub_jar_path].UTF8String;
            NSLog(@"[JavaLauncher] Patching java.desktop with stub SurfaceManagerFactory: %@", cacio_stub_jar_path.lastPathComponent);
        } else {
            NSLog(@"[JavaLauncher] WARNING: stub-surface-manager.jar missing at %@, Caciocavallo may fall back to headless", cacio_stub_jar_path);
        }
    }

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            margv[++margc] = arg.UTF8String;
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
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
        // 传递服务器地址给 PojavLauncher（FCL 风格）：
        // 留空传 @"", Java 端据此判断不追加任何参数；非空则由 Java 端按 MC 版本
        // 解析为 --server/--port 或 --quickPlayMultiplayer
        NSString *serverIp = [PLProfiles.current serverIpForCurrentProfile] ?: @"";
        margv[++margc] = serverIp.UTF8String;
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }
    //margv[++margc] = "ghidra.GhidraRun";

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

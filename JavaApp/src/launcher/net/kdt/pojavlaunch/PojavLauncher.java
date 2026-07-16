package net.kdt.pojavlaunch;

import java.beans.Beans;
import java.io.*;
import java.lang.reflect.Field;
import java.util.*;
import java.util.concurrent.*;

import org.lwjgl.glfw.CallbackBridge;
import org.lwjgl.glfw.GLFW;

import net.kdt.pojavlaunch.uikit.*;
import net.kdt.pojavlaunch.utils.*;
import net.kdt.pojavlaunch.value.*;

public class PojavLauncher {
    private static float currProgress, maxProgress;

    public static void main(String[] args) throws Throwable {
        // Skip calling to com.apple.eawt.Application.nativeInitializeApplicationDelegate()
        Beans.setDesignTime(true);
        try {
            // Some places use macOS-specific code, which is unavailable on iOS
            // In this case, try to get it to use Linux-specific code instead.
            com.apple.eawt.Application.getApplication();
            Class clazz = Class.forName("com.apple.eawt.Application");
            Field field = clazz.getDeclaredField("sApplication");
            field.setAccessible(true);
            field.set(null, null);
            sun.font.FontUtilities.isLinux = true;
            System.setProperty("java.util.prefs.PreferencesFactory", "java.util.prefs.FileSystemPreferencesFactory");
        } catch (Throwable th) {
            // Not on JRE8, ignore exception
            //Tools.showError(th);
        }

        Thread.currentThread().setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {

            public void uncaughtException(Thread t, Throwable th) {
                th.printStackTrace();
                System.exit(1);
            }
        });

        try {
            // Try to initialize Caciocavallo17
            Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCPreloadClassLoader");
        } catch (ClassNotFoundException e) {}

        if (args[0].equals("-jar")) {
            UIKit.callback_JavaGUIViewController_launchJarFile(args[1], Arrays.copyOfRange(args, 2, args.length));
        } else {
            launchMinecraft(args);
        }
    }

    public static void launchMinecraft(String[] args) throws Throwable {
        // Args for Spiral Knights
        System.setProperty("appdir", "./spiral");
        System.setProperty("resource_dir", "./spiral/rsrc");

        String sizeStr = System.getProperty("cacio.managed.screensize");
        System.setProperty("glfw.windowSize", sizeStr);
        String[] size = sizeStr.split("x");
        MCOptionUtils.load();
        MCOptionUtils.set("fullscreen", "false");
        MCOptionUtils.set("overrideWidth", size[0]);
        MCOptionUtils.set("overrideHeight", size[1]);
        // 解锁帧率（关闭垂直同步 + 解除 maxFps 限制）：
        // MC 默认 enableVsync=true，会把帧率锁在屏幕刷新率（60Hz 锁 60、120Hz ProMotion 锁 120）。
        // 同时 MC 默认 maxFps=120，即使关闭 VSync 也会被 maxFps 限制。
        //
        // 当启动器偏好 video.disable_game_vsync 开启时（通过环境变量 POJAV_DISABLE_VSYNC=1 传入）：
        // 1. 强制写 enableVsync=false → MC 不再调用 glfwSwapInterval(1) 请求垂直同步
        // 2. 强制写 maxFps=260 → MC 1.16+ 的源码中 maxFps>=260 时视为"无限制"（unlimited）
        //
        // 关键修复（FPS 解锁无效问题）：
        //   之前使用 maxFps=0，但 MC 的 maxFps 有效值范围是 10-260（默认 120）。
        //   maxFps=0 不是"无限制"——MC 1.16+ 源码中 0 会被当作无效值而忽略，MC 继续使用
        //   options.txt 中的旧值或默认值 120，导致帧率被锁在 120。
        //   MC 1.16+ 源码中有一个特殊判断：if (maxFps >= 260) treat as unlimited。
        //   因此正确的"无限制"设置是 maxFps=260（或更高）。
        //
        //   对于 MC 1.8-1.15 旧版本：maxFps 选项不存在或行为不同，此设置会被忽略，
        //   帧率解锁完全依赖 native 层的 eglSwapInterval(0) 拦截。
        //
        // MC 26.2+ 兼容性（关键修复）：
        //   MC 26.2 可能重命名了选项。同时写入多种可能的选项名以确保兼容：
        //   - maxFps（MC 1.16-1.21）：帧率上限
        //   - maxFramerate（MC 26.2+ 可能的新名称）：帧率上限
        //   - enableVsync（所有版本）：垂直同步开关
        //   - framerateLimit（MC 26.2+ 可能的替代名称）：帧率限制
        //
        // 这样做的效果：
        // - Vulkan 渲染器（MoltenVK）：LWJGL 创建 swapchain 时使用 VK_PRESENT_MODE_IMMEDIATE_KHR，
        //   MoltenVK 不等待 vblank 直接 present，帧率可超过屏幕刷新率（减少输入延迟）
        // - GL 类渲染器（ANGLE Metal）：eglSwapInterval(0) 让渲染线程不阻塞，
        //   但 Core Animation 仍按屏幕刷新率合成（实际帧率不超过屏幕刷新率，但渲染线程吞吐量提高）
        //
        // 用 set（而非 setDefault）覆盖：每次启动都强制关闭，确保生效；
        // 用户若想恢复游戏内垂直同步和帧率限制，可在启动器设置关闭该开关。
        if ("1".equals(System.getenv("POJAV_DISABLE_VSYNC"))) {
            MCOptionUtils.set("enableVsync", "false");
            // maxFps=260：MC 1.16+ 源码中 maxFps>=260 视为 unlimited
            // （之前用 0 会被当作无效值忽略，导致帧率仍被 maxFps=120 限制）
            MCOptionUtils.set("maxFps", "260");
            // MC 26.2+ 兼容：可能重命名为 maxFramerate 或 framerateLimit
            MCOptionUtils.set("maxFramerate", "260");
            MCOptionUtils.set("framerateLimit", "260");
            // 诊断日志：输出写入的帧率相关选项
            System.out.println("[PojavLauncher] VSync disabled, maxFps/maxFramerate/framerateLimit set to 260");
            System.out.println("[PojavLauncher]   enableVsync=" + MCOptionUtils.get("enableVsync"));
            System.out.println("[PojavLauncher]   maxFps=" + MCOptionUtils.get("maxFps"));
            System.out.println("[PojavLauncher]   maxFramerate=" + MCOptionUtils.get("maxFramerate"));
            System.out.println("[PojavLauncher]   framerateLimit=" + MCOptionUtils.get("framerateLimit"));
        }
        // Default settings for performance
        MCOptionUtils.setDefault("mipmapLevels", "0");
        MCOptionUtils.setDefault("particles", "1");
        MCOptionUtils.setDefault("renderDistance", "2");
        MCOptionUtils.setDefault("simulationDistance", "5");
        
        MCOptionUtils.save();

        // Setup Forge splash.properties
        File forgeSplashFile = new File(Tools.DIR_GAME_NEW, "config/splash.properties");
        if (System.getProperty("pojav.internal.keepForgeSplash") == null) {
            forgeSplashFile.getParentFile().mkdir();
            if (forgeSplashFile.exists()) {
                Tools.write(forgeSplashFile.getAbsolutePath(), Tools.read(forgeSplashFile.getAbsolutePath().replace("enabled=true", "enabled=false")));
            } else {
                Tools.write(forgeSplashFile.getAbsolutePath(), "enabled=false");
            }
        }

        // 仅在显式选择 Vulkan 渲染器时设置 LWJGL Vulkan native 库名称，
        // 避免覆盖 JavaLauncher.m 为 ANGLE/MobileGlues/GL4ES 设置的 OpenGL libname。
        // 注意：LWJGL Library.loadNative 在 macOS 上会自动加 "lib" 前缀和 ".dylib" 后缀，
        // 所以这里必须传裸名 "MoltenVK"，否则 "libMoltenVK.dylib" 会被二次包装成
        // "liblibMoltenVK.dylib.dylib" 导致 UnsatisfiedLinkError。
        String renderer = System.getenv("AMETHYST_RENDERER");
        if ("libMoltenVK.dylib".equals(renderer) || "vulkan".equals(renderer)) {
            System.setProperty("org.lwjgl.vulkan.libname", "MoltenVK");
        }

        MinecraftAccount account = MinecraftAccount.load(args[0]);
        JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);
        System.out.println("Launching Minecraft " + version.id);

        // 第三个参数为服务器地址（FCL 风格）：留空则不自动加入，非空则启动后自动加入
        // 由 JavaLauncher.m 在 NSDictionary 启动分支以 args[2] 传入
        String serverIp = (args.length > 2 && args[2] != null) ? args[2] : "";

        // Set language to Chinese on first launch
        // For Minecraft 1.11 and later: zh_cn (lowercase)
        // For Minecraft 1.6 to 1.10: zh_CN (uppercase)
        // For Minecraft 1.1 to 1.5: zh_CN (uppercase, lowercase crashes)
        MCOptionUtils.load();
        String minecraftVersion = version.id;
        if (minecraftVersion.compareTo("1.11") >= 0) {
            MCOptionUtils.setDefault("lang", "zh_cn");
        } else if (minecraftVersion.compareTo("1.1") >= 0) {
            MCOptionUtils.setDefault("lang", "zh_CN");
        }
        // For Minecraft 1.0 and earlier, no language option
        MCOptionUtils.save();
        String configPath;
        if (version.logging != null) {
            if (version.logging.client.file.id.equals("client-1.12.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
            } else {
                configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
            }
            System.setProperty("log4j.configurationFile", configPath);
        }

        Tools.launchMinecraft(account, version, serverIp);
    }
}

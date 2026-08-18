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
        // Unlock the frame rate (disable vertical sync + lift the maxFps limit):
        // MC defaults to enableVsync=true, which locks the frame rate to the screen refresh rate (60 on a 60Hz screen, 120 on a 120Hz ProMotion screen).
        // MC also defaults to maxFps=120, so even with VSync off the frame rate is capped by maxFps.
        //
        // When the launcher preference video.disable_game_vsync is on (passed in through the environment variable POJAV_DISABLE_VSYNC=1):
        // 1. enableVsync=false is written by force → MC no longer calls glfwSwapInterval(1) to request vertical sync
        // 2. maxFps=260 is written by force → in the MC 1.16+ source, maxFps>=260 is treated as "unlimited"
        //
        // Key fix (frame rate unlocking not working):
        //   maxFps=0 used to be written, but MC's valid maxFps range is 10-260 (the default is 120).
        //   maxFps=0 does not mean "unlimited" - in the MC 1.16+ source 0 is treated as invalid and ignored, so MC keeps using
        //   the old value in options.txt or the default of 120, locking the frame rate at 120.
        //   The MC 1.16+ source has a special check: if (maxFps >= 260) treat as unlimited.
        //   So the correct "unlimited" setting is maxFps=260 (or higher).
        //
        //   On older MC 1.8-1.15 versions the maxFps option does not exist or behaves differently, so this setting is ignored
        //   and unlocking the frame rate relies entirely on the native layer intercepting eglSwapInterval(0).
        //
        // MC 26.2+ compatibility (key fix):
        //   MC 26.2 may have renamed the options. Several possible option names are written for compatibility:
        //   - maxFps (MC 1.16-1.21): the frame rate cap
        //   - maxFramerate (a possible new name in MC 26.2+): the frame rate cap
        //   - enableVsync (every version): the vertical sync toggle
        //   - framerateLimit (a possible alternative name in MC 26.2+): the frame rate limit
        //
        // What this achieves:
        // - Vulkan renderer (MoltenVK): LWJGL creates the swapchain with VK_PRESENT_MODE_IMMEDIATE_KHR,
        //   so MoltenVK presents without waiting for vblank and the frame rate can exceed the screen refresh rate (reducing input latency)
        // - GL-family renderers (ANGLE Metal): eglSwapInterval(0) keeps the render thread unblocked,
        //   although Core Animation still composites at the screen refresh rate (so the actual frame rate does not exceed it, but render thread throughput improves)
        //
        // set (rather than setDefault) is used to override: it is forced off on every launch to make sure it takes effect;
        // a user who wants the in-game vertical sync and frame rate limit back can turn the toggle off in the launcher settings.
        if ("1".equals(System.getenv("POJAV_DISABLE_VSYNC"))) {
            MCOptionUtils.set("enableVsync", "false");
            // maxFps=260: in the MC 1.16+ source, maxFps>=260 counts as unlimited
            // (0 used to be written, but it was treated as invalid and ignored, so the frame rate stayed capped at maxFps=120)
            MCOptionUtils.set("maxFps", "260");
            // MC 26.2+ compatibility: it may have been renamed to maxFramerate or framerateLimit
            MCOptionUtils.set("maxFramerate", "260");
            MCOptionUtils.set("framerateLimit", "260");
            // MC 1.21.8+ compatibility: the inactivityFpsLimit option (the InactivityFpsLimit enum)
            //
            // Key fix (one root cause of frame rate unlocking not working):
            // MC 1.21.8+ introduced an "inactivity frame rate limit" feature (inactivityFpsLimit),
            // whose default value is "afk":
            //   - after 1 minute without input the frame rate drops to 30 FPS
            //   - after 10 minutes without input it drops to 10 FPS
            //   - when the window is minimized it drops to 10 FPS
            // On iOS this severely limits the frame rate whenever the user backgrounds the app or stops interacting,
            // no matter whether VSync and the maxFps cap have been turned off.
            //
            // The InactivityFpsLimit enum has only two values:
            //   - "afk" (the default): AFK mode, limiting the frame rate while idle
            //   - "minimized": limit the frame rate only while minimized (10 FPS)
            //
            // With it set to "minimized" the frame rate is not limited while the user is idle,
            // only while the window is minimized (which almost never happens on iOS).
            // Combined with VSync off and maxFps=260, this genuinely unlocks the frame rate.
            //
            // Older MC versions (1.21.7 and below) do not recognize this option and ignore it, with no side effects.
            MCOptionUtils.set("inactivityFpsLimit", "minimized");
            // Diagnostic log: print the frame-rate-related options that were written
            System.out.println("[PojavLauncher] VSync disabled, maxFps/maxFramerate/framerateLimit set to 260");
            System.out.println("[PojavLauncher]   enableVsync=" + MCOptionUtils.get("enableVsync"));
            System.out.println("[PojavLauncher]   maxFps=" + MCOptionUtils.get("maxFps"));
            System.out.println("[PojavLauncher]   maxFramerate=" + MCOptionUtils.get("maxFramerate"));
            System.out.println("[PojavLauncher]   framerateLimit=" + MCOptionUtils.get("framerateLimit"));
            System.out.println("[PojavLauncher]   inactivityFpsLimit=" + MCOptionUtils.get("inactivityFpsLimit"));
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

        // The LWJGL Vulkan native library name is only set when the Vulkan renderer is explicitly selected,
        // so it does not override the OpenGL libname JavaLauncher.m sets for ANGLE/MobileGlues/GL4ES.
        // Note: on macOS, LWJGL's Library.loadNative adds the "lib" prefix and the ".dylib" suffix automatically,
        // so the bare name "MoltenVK" must be passed here, otherwise "libMoltenVK.dylib" would be wrapped again into
        // "liblibMoltenVK.dylib.dylib" and produce an UnsatisfiedLinkError.
        String renderer = System.getenv("AMETHYST_RENDERER");
        if ("libMoltenVK.dylib".equals(renderer) || "vulkan".equals(renderer)) {
            System.setProperty("org.lwjgl.vulkan.libname", "MoltenVK");
        }

        // MC 26.2+ Graphics API switching (choosing the in-game OpenGL/Vulkan graphics backend)
        //
        // Mojang introduced the "Graphics API" video setting in MC 26.2 Snapshot 1, with 3 values:
        //   - default        decided by Mojang (Vulkan for 26.2-snapshot-1 through 7, OpenGL for snapshot-8+)
        //   - prefer_vulkan  prefer Vulkan, falling back to OpenGL on failure
        //   - prefer_opengl  prefer OpenGL, falling back to Vulkan on failure
        //
        // Note: graphicsApi here and the launcher's renderer (which native library to use: libgl4es/libMoltenVK and so on)
        // are two different dimensions:
        //   - renderer: which native renderer library the launcher loads (the LWJGL layer)
        //   - graphicsApi: whether MC 26.2+ internally takes the OpenGL or the Vulkan path (the game layer)
        //
        // When the user selects prefer_vulkan it is advisable to also set renderer to libMoltenVK.dylib
        // (the UI recommends it but does not force the pairing, so advanced users can configure them separately).
        //
        // Older MC versions (1.21.7 and below) do not recognize the graphicsApi field in options.txt
        // and ignore it, with no side effects.
        //
        // Key fix (changing the graphics API had no effect):
        //   Previously a graphicsApi of "default" was skipped entirely and nothing was written to options.txt.
        //   That meant when the user switched back to default from prefer_vulkan/prefer_opengl,
        //   the stale value left in options.txt was never cleared and MC kept using it rather than its internal default.
        //   It now does the following:
        //   - "default": remove the graphicsApi line from options.txt, so MC uses its internal default
        //   - prefer_vulkan/prefer_opengl: write the matching value (overwriting the old one)
        String graphicsApi = System.getenv("AMETHYST_GRAPHICS_API");
        if (graphicsApi != null && !graphicsApi.isEmpty()) {
            MCOptionUtils.load();
            if ("default".equalsIgnoreCase(graphicsApi)) {
                // When "Default" is selected, remove the graphicsApi line from options.txt
                // so MC 26.2+ uses its internal default behavior (it does not read the field)
                MCOptionUtils.remove("graphicsApi");
                System.out.println("[PojavLauncher] MC 26.2+ graphicsApi cleared (default)");
            } else {
                String normalized;
                if ("vulkan".equalsIgnoreCase(graphicsApi) || "prefer_vulkan".equalsIgnoreCase(graphicsApi)) {
                    normalized = "prefer_vulkan";
                } else if ("opengl".equalsIgnoreCase(graphicsApi) || "prefer_opengl".equalsIgnoreCase(graphicsApi)) {
                    normalized = "prefer_opengl";
                } else {
                    normalized = graphicsApi.toLowerCase();
                }
                MCOptionUtils.set("graphicsApi", normalized);
                System.out.println("[PojavLauncher] MC 26.2+ graphicsApi set to " + normalized);
            }
            MCOptionUtils.save();
        }

        MinecraftAccount account = MinecraftAccount.load(args[0]);
        JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);
        System.out.println("Launching Minecraft " + version.id);

        // The third argument is the server address (FCL style): leave it empty to not auto-join, or set it to auto-join after launch
        // It is passed in by JavaLauncher.m as args[2] in the NSDictionary launch branch
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
        String configPath = null;
        if (version.logging != null) {
            if (version.logging.client.file.id.equals("client-1.12.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
            } else {
                configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
            }
        }
        // Fallback: use the 1.12 patched configuration when the logging configuration is missing or the file does not exist
        // This makes sure MC logs reach stdout, which helps diagnose launch crashes
        if (configPath == null || !new java.io.File(configPath).exists()) {
            configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            System.out.println("[PojavLauncher] Using fallback log4j config: " + configPath);
        }
        System.setProperty("log4j.configurationFile", configPath);

        Tools.launchMinecraft(account, version, serverIp);
    }
}

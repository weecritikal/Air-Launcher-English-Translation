package net.kdt.pojavlaunch.uikit;

import java.io.*;
import java.lang.reflect.*;
import java.util.jar.*;
import net.kdt.pojavlaunch.utils.MCOptionUtils;
import net.kdt.pojavlaunch.*;
import org.lwjgl.glfw.*;

public class UIKit {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_MOVE_MOTION = 3;

    private static int guiScale;

    private static void patch_FlatLAF_setLinux() {
        String osName = System.getProperty("os.name");
        System.setProperty("os.name", "Linux");
        try {
            Class<?> clazz = ClassLoader.getSystemClassLoader().loadClass("com.formdev.flatlaf.util.SystemInfo");
            // trigger static init
            clazz.getField("isMacOS").get(null);
        } catch (Throwable e) {
            System.out.println("Skipped patch_FlatLAF_setLinux");
            //e.printStackTrace();
        }
        System.setProperty("os.name", osName);
    }

    public static void callback_JavaGUIViewController_launchJarFile(final String filepath, String[] args) throws Throwable {
        // Launch the JAR file
        // try-with-resources makes sure the JarFile is closed, so no file descriptor leaks
        String mainClass;
        try (JarFile jarfile = new JarFile(filepath)) {
            if (jarfile.getManifest() == null) {
                throw new IllegalArgumentException("no manifest in \"" + filepath + "\"");
            }
            mainClass = jarfile.getManifest().getMainAttributes().getValue("Main-Class");
        }
        if (mainClass == null) {
            throw new IllegalArgumentException("no main manifest attribute, in \"" + filepath + "\"");
        }

        // LabyMod Installer uses FlatLAF which has some macOS-specific codes, so we make it think it's running on Linux.
        patch_FlatLAF_setLinux();

        // A URLClassLoader loads the JAR, supporting JarInJar (the installers of some Forge/NeoForge versions embed JAR dependencies)
        // The parent ClassLoader is the system ClassLoader, so the PojavLauncher/UIKit bridge classes can still be loaded
        java.net.URL[] urls = new java.net.URL[]{new java.io.File(filepath).toURI().toURL()};
        ClassLoader loader = new java.net.URLClassLoader(urls, ClassLoader.getSystemClassLoader());
        Class<?> clazz = loader.loadClass(mainClass);
        Method method = clazz.getMethod("main", String[].class);
        try {
            method.invoke(null, new Object[]{args});
        } catch (java.lang.reflect.InvocationTargetException ite) {
            // Unwrap the InvocationTargetException to expose the real exception from the installer's main method
            Throwable cause = ite.getCause();
            if (cause != null) {
                throw cause;
            }
            throw ite;
        }
    }

    public static void updateMCGuiScale() {
        MCOptionUtils.load();
        String str = MCOptionUtils.get("guiScale");
        guiScale = (str == null ? 0 :Integer.parseInt(str));

        int scale = Math.max(Math.min(GLFW.mGLFWWindowWidth / 320, GLFW.mGLFWWindowHeight / 240), 1);
        if(scale < guiScale || guiScale == 0){
            guiScale = scale;
        }
        updateMCGuiScale(guiScale);
    }

    static {
        System.load(System.getenv("BUNDLE_PATH") + "/Flux");
    }


    // public static native void runOnUIThread(UIKitCallback callback);

    public static native void showError(String title, String message, boolean exitIfOk);

    private static native void updateMCGuiScale(int scale);
}

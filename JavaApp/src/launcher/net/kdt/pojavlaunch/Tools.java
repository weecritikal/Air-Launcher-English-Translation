package net.kdt.pojavlaunch;

import android.util.ArrayMap;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileFilter;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import net.kdt.pojavlaunch.uikit.UIKit;
import net.kdt.pojavlaunch.utils.JSONUtils;
import net.kdt.pojavlaunch.value.DependentLibrary;
import net.kdt.pojavlaunch.value.MinecraftAccount;
import net.kdt.pojavlaunch.value.MinecraftLibraryArtifact;

public final class Tools {
    public static final Gson GLOBAL_GSON = new GsonBuilder().setPrettyPrinting().create();

    public static final String DIR_BUNDLE = System.getenv("BUNDLE_PATH"); // path to "PojavLauncher.app"
    public static final String DIR_GAME_HOME = System.getenv("POJAV_HOME");
    public static final String DIR_GAME_NEW = System.getenv("POJAV_GAME_DIR"); // path to "Library/Application Support/minecraft"
    public static final String DIR_GAME_PROFILE = System.getProperty("user.dir");
    
    public static final String DIR_APP_DATA = System.getenv("POJAV_HOME");
    public static final String DIR_ACCOUNT_NEW = DIR_APP_DATA + "/accounts";

    // New since 2.4.2
    public static final String DIR_HOME_VERSION = DIR_GAME_NEW + "/versions";
    public static final String DIR_HOME_LIBRARY = DIR_GAME_NEW + "/libraries";

    public static final String ASSETS_PATH = DIR_GAME_NEW + "/assets";
    public static final String OBSOLETE_RESOURCES_PATH=DIR_GAME_NEW + "/resources";

    public static void launchMinecraft(MinecraftAccount profile, final JMinecraftVersionList.Version versionInfo, String serverIp) throws Throwable {
        // --- BEGIN AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---
        // Turn off the native libffi check (preventing a NoSuchFieldError inside LibFFI's <clinit>)
        // Note: the allocator is configured centrally by JavaLauncher.m via -Dorg.lwjgl.system.allocator=system,
        // so it is not set again here. The original System.setProperty("org.lwjgl.system.Allocator", "Custom")
        // had two fatal problems that meant it never took effect and misled debugging:
        //   1) The property name had the wrong case: LWJGL actually reads the lowercase org.lwjgl.system.allocator, and the capitalized Allocator was ignored
        //   2) "Custom" is not a valid LWJGL allocator value (only system/jemalloc/rpmalloc are valid)
        System.setProperty("org.lwjgl.system.libffi.enabled", "false");
        System.setProperty("org.lwjgl.system.libffi.initialize", "false"); // Prevents NoSuchFieldError in LibFFI <clinit>

        // Notes on loading the spvc / openal libraries:
        // The spvc library name is set explicitly by JavaLauncher.m with -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0
        // (modeled on catsruledogs/Amethyst-iOS-25, which starts 26.2 + Java 25 correctly).
        // How LWJGL's Library.loadNative treats libname on macOS:
        //   - if libname already has the "lib" prefix and the ".dylib" suffix, it is used as is
        //   - otherwise the "lib" prefix and ".dylib" suffix are added
        // "spirv-cross-c-shared.0" -> "libspirv-cross-c-shared.0.dylib" (correct, with no double wrapping).
        // spirv-cross ships as a shared dylib in the root Frameworks/ directory and is loaded from the root Frameworks/
        // of library.path (Frameworks:Frameworks/lwjglXX).
        //
        // openal is loaded as libopenal.dylib under LWJGL's default name (libopenal.dylib is present directly in the root Frameworks/),
        // so no override is needed.
        //
        // A lesson from history: removing the spvc.libname override was tried once, in favor of a Makefile symlink
        // (libspirv-cross.dylib -> libspirv-cross-c-shared.0.dylib) plus LWJGL's default name "spirv-cross",
        // but 26.2 then hit a SIGSEGV at get_method_id during the "Now starting game" phase. The root cause: the symlink approach
        // depends on the build stage creating the symlink correctly, and once a build environment difference leaves the symlink missing or pointing at the wrong file, spvc loading
        // enters a bad state, the JNI registration state becomes inconsistent, and get_method_id accesses corrupted class metadata and SIGSEGVs
        // (instead of throwing an UnsatisfiedLinkError). Naming the full shared object explicitly locates the real file directly, needs no symlink,
        // and is the most robust approach.
        // --- END AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---

        String[] launchArgs = getMinecraftArgs(profile, versionInfo, serverIp);
        // System.out.println("Minecraft Args: " + Arrays.toString(launchArgs));

        final String launchClassPath = generateLaunchClassPath(versionInfo);

        System.out.println("Args init finished. Now starting game");

        PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
        // add launcher.jar itself
        for (String s : System.getProperty("java.class.path").split(":")) {
            loader.appendToClassPathForInstrumentation(s);
        }
        for (String s : launchClassPath.split(":")) {
            if (!s.isEmpty()) {
                loader.addURL(new File(s).toURI().toURL());
            }
        }
            
        Class<?> clazz = loader.loadClass(versionInfo.mainClass);
        Method method = clazz.getMethod("main", String[].class);
        method.invoke(null, new Object[]{launchArgs});
    }

    public static String[] getMinecraftArgs(MinecraftAccount profile, JMinecraftVersionList.Version versionInfo, String serverIp) {
        String username = profile.username.replace("Demo.", "");
        String versionName = versionInfo.id;
        if (versionInfo.inheritsFrom != null) {
            versionName = versionInfo.inheritsFrom;
        }

        File gameDir = new File(Tools.DIR_GAME_PROFILE);
        gameDir.mkdirs();
        // Make sure the logs directory exists, so the Log4j RollingRandomAccessFileAppender does not
        // throw a FileNotFoundException because the logs/latest.log path does not exist
        new File(gameDir, "logs").mkdirs();

        Map<String, String> varArgMap = new ArrayMap<String, String>();
        varArgMap.put("auth_session", profile.accessToken); // For legacy versions of MC
        varArgMap.put("auth_access_token", profile.accessToken);
        varArgMap.put("auth_player_name", username);
        varArgMap.put("auth_uuid", profile.profileId.replace("-", ""));
        varArgMap.put("auth_xuid", profile.xuid);
        varArgMap.put("assets_root", Tools.ASSETS_PATH);
        varArgMap.put("assets_index_name", versionInfo.assets);
        varArgMap.put("clientid", profile.clientToken);
        varArgMap.put("game_assets", Tools.ASSETS_PATH);
        varArgMap.put("game_directory", gameDir.getAbsolutePath());
        varArgMap.put("user_properties", "{}");
        varArgMap.put("user_type", "mojang");
        varArgMap.put("version_name", versionName);
        varArgMap.put("version_type", versionInfo.type);
        varArgMap.put("natives_directory", System.getProperty("java.library.path"));

        List<String> minecraftArgs = new ArrayList<String>();
        if (versionInfo.arguments != null) {
            // Support Minecraft 1.13+
            // Detect whether the current account uses third-party authentication (authlib-injector / Yggdrasil)
            // The signature of a third-party account: clientToken is not "0" and xuid is null or "0"
            // (Microsoft accounts have an xuid, and local accounts have clientToken "0")
            // For a third-party account, user_type must stay "mojang" even when the version JSON contains the --xuid argument
            // and must not be changed to "msa", otherwise Minecraft 26.x internally follows the MSA flow
            // and authentication fails (skins do not load / servers cannot be joined / it crashes)
            boolean isThirdPartyAccount = !"0".equals(profile.clientToken)
                && (profile.xuid == null || "0".equals(profile.xuid));
            for (Object arg : versionInfo.arguments.game) {
                if (arg instanceof String) {
                    minecraftArgs.add((String) arg);
                    if (arg.equals("--xuid") && !isThirdPartyAccount) {
                        // Only set user_type=msa for Microsoft accounts (the ones with an xuid)
                        // Third-party accounts keep "mojang", so the 26.x authentication flow is not taken by mistake
                        varArgMap.put("user_type", "msa");
                    }
                } else {
                    /*
                    JMinecraftVersionList.Arguments.ArgValue argv = (JMinecraftVersionList.Arguments.ArgValue) arg;
                    if (argv.values != null) {
                        minecraftArgs.add(argv.values[0]);
                    } else {
                        
                         for (JMinecraftVersionList.Arguments.ArgValue.ArgRules rule : arg.rules) {
                         // rule.action = allow
                         // TODO implement this
                         }
                         
                    }
                    */
                }
            }
        }
        String[] argsFromJson = JSONUtils.insertJSONValueList(
            splitAndFilterEmpty(
                versionInfo.minecraftArguments == null ?
                fromStringArray(minecraftArgs.toArray(new String[0])):
                versionInfo.minecraftArguments,
                profile
            ), varArgMap
        );

        // FCL style: join a server automatically after launch. When serverIp is empty no argument is appended,
        // so the behavior matches the original launch flow exactly. The version check uses the resolved base MC version number
        // (versionName prefers inheritsFrom, so a modded version id does not interfere with the comparison)
        argsFromJson = appendServerArgs(argsFromJson, serverIp, versionName);

        // Tools.dialogOnUiThread(this, "Result args", Arrays.asList(argsFromJson).toString());
        return argsFromJson;
    }

    /**
     * Append the server-join arguments based on serverIp and the MC version (FCL/ZL2 style).
     * - MC < 1.20: --server <host> --port <port> (defaulting the port to 25565)
     * - MC >= 1.20: --quickPlayMultiplayer <host:port> (defaulting the port to :25565)
     * - Address formats: host / host:port / [ipv6]:port
     * - A parse failure only warns and skips joining, without throwing
     * - When serverIp is null or an empty string the original arguments are returned unchanged
     */
    private static String[] appendServerArgs(String[] args, String serverIp, String versionId) {
        if (serverIp == null || serverIp.isEmpty()) {
            return args;
        }
        String trimmed = serverIp.trim();
        if (trimmed.isEmpty()) {
            return args;
        }

        String host = null;
        String port = "25565"; // The default port

        // Address parsing: supports host / host:port / [ipv6]:port
        if (trimmed.startsWith("[")) {
            // IPv6 takes the form [::1]:25565 or [::1]
            int close = trimmed.indexOf("]");
            if (close <= 0) {
                System.err.println("[Tools] Invalid server address (unterminated IPv6 bracket): " + serverIp);
                return args;
            }
            host = trimmed.substring(1, close);
            if (close + 1 < trimmed.length()) {
                // The bracket should be followed by :port
                String rest = trimmed.substring(close + 1);
                if (rest.startsWith(":")) {
                    String portStr = rest.substring(1);
                    if (!portStr.isEmpty()) {
                        port = portStr;
                    }
                } else if (!rest.isEmpty()) {
                    System.err.println("[Tools] Invalid server address (unexpected chars after IPv6 bracket): " + serverIp);
                    return args;
                }
            }
        } else {
            // A normal address: split off the port at the last :
            int lastColon = trimmed.lastIndexOf(":");
            if (lastColon > 0) {
                host = trimmed.substring(0, lastColon);
                String portStr = trimmed.substring(lastColon + 1);
                if (!portStr.isEmpty()) {
                    port = portStr;
                }
            } else {
                host = trimmed;
            }
        }

        if (host == null || host.isEmpty()) {
            System.err.println("[Tools] Invalid server address (empty host): " + serverIp);
            return args;
        }

        List<String> argList = new ArrayList<String>(Arrays.asList(args));
        // Version check: MC < 1.20 uses --server/--port, MC >= 1.20 uses --quickPlayMultiplayer
        if (versionId.compareTo("1.20") < 0) {
            argList.add("--server");
            argList.add(host);
            argList.add("--port");
            argList.add(port);
            System.out.println("[Tools] Auto-join server (legacy): " + host + ":" + port);
        } else {
            argList.add("--quickPlayMultiplayer");
            argList.add(host + ":" + port);
            System.out.println("[Tools] Auto-join server (quickPlay): " + host + ":" + port);
        }
        return argList.toArray(new String[0]);
    }

    public static String fromStringArray(String[] strArr) {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < strArr.length; i++) {
            if (i > 0) builder.append(" ");
            builder.append(strArr[i]);
        }

        return builder.toString();
    }

    private static String[] splitAndFilterEmpty(String argStr, MinecraftAccount profile) {
        List<String> strList = new ArrayList<String>();
        if(profile.username.startsWith("Demo.")) {
            strList.add("--demo");
        }
        for (String arg : argStr.split(" ")) {
            if (!arg.isEmpty()) {
                strList.add(arg);
            }
        }
        return strList.toArray(new String[0]);
    }

    public static String artifactToPath(DependentLibrary library) {
        if (library.downloads != null &&
            library.downloads.artifact != null &&
            library.downloads.artifact.path != null)
            return library.downloads.artifact.path;
        String[] libInfos = library.name.split(":");
        return libInfos[0].replaceAll("\\.", "/") + "/" + libInfos[1] + "/" + libInfos[2] + "/" + libInfos[1] + "-" + libInfos[2] + ".jar";
    }

/*
    private static String getLWJGL3ClassPath() {
        StringBuilder libStr = new StringBuilder();
        File lwjgl3Folder = new File(Tools.DIR_GAME_NEW, "lwjgl3");
        if (/* info.arguments != null && @lwjgl3Folder.exists()) {
            for (File file: lwjgl3Folder.listFiles()) {
                if (file.getName().endsWith(".jar")) {
                    libStr.append(file.getAbsolutePath() + ":");
                }
            }
            // Remove the ':' at the end
            libStr.setLength(libStr.length() - 1);
        }
        return libStr.toString();
    }
*/
    public static String generateLaunchClassPath(JMinecraftVersionList.Version info) {
        StringBuilder libStr = new StringBuilder(); //versnDir + "/" + version + "/" + version + ".jar:";

        String[] classpath = generateLibClasspath(info);

        // Debug: LWJGL 3 override
        // File lwjgl2Folder = new File(Tools.MAIN_PATH, "lwjgl2");

        /*
         File lwjgl3Folder = new File(Tools.MAIN_PATH, "lwjgl3");
         if (lwjgl3Folder.exists()) {
         for (File file: lwjgl3Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         } else if (lwjgl2Folder.exists()) {
         for (File file: lwjgl2Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         }
         */

        for (String perJar : classpath) {
            if (!new File(perJar).exists()) {
                System.out.println("Ignored non-exists file: " + perJar);
                continue;
            }
            libStr.append(perJar + ":");
        }
        libStr.append(DIR_HOME_VERSION + "/" + info.id + "/" + info.id + ".jar");

        return libStr.toString();
    }
    
    public static void moveInside(String from, String to) {
        File fromFile = new File(from);
        for (File fromInside : fromFile.listFiles()) {
            moveRecursive(fromInside.getAbsolutePath(), to);
        }
        fromFile.delete();
    }

    public static void moveRecursive(String from, String to) {
        moveRecursive(new File(from), new File(to));
    }

    public static void moveRecursive(File from, File to) {
        File toFrom = new File(to, from.getName());
        try {
            if (from.isDirectory()) {
                for (File child : from.listFiles()) {
                    moveRecursive(child, toFrom);
                }
            }
        } finally {
            from.getParentFile().mkdirs();
            from.renameTo(toFrom);
        }
    }

    public static void preProcessLibraries(DependentLibrary[] libraries) {
        // Ignore some libraries since they are unsupported (jinput) or unused (LWJGL)
        for (int i = 0; i < libraries.length; i++) {
            DependentLibrary libItem = libraries[i];

            // text2speech drives the narrator, which does nothing here, so this used to be dropped
            // wholesale. That is fine for vanilla - Minecraft falls back to a no-op narrator - but
            // Mixin resolves class metadata for the *types a method mentions* while transforming,
            // and Minecraft's constructor mentions com.mojang.text2speech. With the jar off the
            // classpath, every modpack that mixins into Minecraft died during startup with
            //   ClassMetadataNotFoundException: com.mojang.text2speech.OperatingSystem
            // wrapped in a MixinTransformerError, naming a class nobody had ever asked for.
            // The plain jar is pure Java, is already downloaded, and is present in every desktop
            // install, so it goes on the classpath. Only the platform natives are dropped - those
            // carry a classifier as a fourth coordinate component.
            if (libItem.name.startsWith("com.mojang:text2speech")) {
                if (libItem.name.split(":").length > 3) {
                    libItem._skip = true;
                }
                continue;
            }

            if (//libItem.name.startsWith("net.java.jinput") ||
                libItem.name.startsWith("net.java.dev.jna:platform:") ||
                libItem.name.startsWith("org.lwjgl") ||
                libItem.name.startsWith("tv.twitch")) {
                    libItem._skip = true;
                    continue;
            }

            String[] version = libItem.name.split(":")[2].split("\\.");
            if (libItem.name.startsWith("net.java.dev.jna:jna:")) {
                // Force JNA to 5.13.0 to guarantee iOS compatibility.
                // MC 26.3+ requires JNA 5.17.0, but its darwin-aarch64 libjnidispatch causes a native crash/hang on iOS
                // once IOKit/CoreFoundation are loaded (26.2 + JNA 5.13.0 works fine).
                // MC does not use the JNA API directly (it uses it indirectly through oshi), and 5.13.0's API is fully compatible.
                // PatchJNAAgent replaces Platform.class regardless of the JNA jar version.
                if (Integer.parseInt(version[0]) == 5 && Integer.parseInt(version[1]) == 13 && Integer.parseInt(version[2]) == 0) continue;
                System.out.println("[Tools] Replacing JNA " + version[0] + "." + version[1] + "." + version[2] + " with 5.13.0 for iOS compatibility");

createLibraryInfo(libItem);
                libItem.name = "net.java.dev.jna:jna:5.13.0";
                libItem.downloads.artifact.path = "net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
                libItem.downloads.artifact.url = "https://libraries.minecraft.net/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            } else if (libItem.name.startsWith("org.ow2.asm:asm-all:")) {
                if(Integer.parseInt(version[0]) >= 5) continue;
                //System.out.println("Library " + libItem.name + " has been changed to version 5.0.4");
                createLibraryInfo(libItem);
                libItem.name = "org.ow2.asm:asm-all:5.0.4";
                libItem.url = null;
                libItem.downloads.artifact.path = "org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
                libItem.downloads.artifact.sha1 = "e6244859997b3d4237a552669279780876228909";
                libItem.downloads.artifact.url = "https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            }
        }
    }

    private static void createLibraryInfo(DependentLibrary library) {
        if(library.downloads == null || library.downloads.artifact == null)
            library.downloads = new DependentLibrary.LibraryDownloads(new MinecraftLibraryArtifact());
    }

    public static String[] generateLibClasspath(JMinecraftVersionList.Version info) {
        List<String> libDir = new ArrayList<String>();

        preProcessLibraries(info.libraries);
        for (DependentLibrary libItem : info.libraries) {
            if (libItem._skip) continue;
            String fullPath = Tools.DIR_HOME_LIBRARY + "/" + artifactToPath(libItem);
            if (!libDir.contains(fullPath)) {
                libDir.add(fullPath);
            }
        }
        return libDir.toArray(new String[0]);
    }

    /// A version JSON may legitimately declare no libraries of its own - a profile that only
    /// overrides the main class or the arguments is valid, and a modloader profile can arrive
    /// that way. Reading the array without checking failed the whole launch with
    /// "Cannot read the array length because <local4> is null", which names nothing the player
    /// can act on. Absent is treated as empty so the merge carries on with the other side's.
    private static DependentLibrary[] librariesOrEmpty(JMinecraftVersionList.Version version) {
        if (version == null || version.libraries == null) {
            return new DependentLibrary[0];
        }
        return version.libraries;
    }

    public static JMinecraftVersionList.Version getVersionInfo(String versionName) {
        try {
            JMinecraftVersionList.Version customVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + versionName + "/" + versionName + ".json"), JMinecraftVersionList.Version.class);
            if (customVer.inheritsFrom == null || customVer.inheritsFrom.equals(customVer.id)) {
                return customVer;
            } else {
                JMinecraftVersionList.Version inheritsVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + customVer.inheritsFrom + "/" + customVer.inheritsFrom + ".json"), JMinecraftVersionList.Version.class);
                inheritsVer.inheritsFrom = inheritsVer.id;
                
                insertSafety(inheritsVer, customVer,
                             "assetIndex", "assets", "id",
                             "mainClass", "minecraftArguments",
                             "releaseTime", "time", "type"
                             );

                // Go through the libraries, remove the ones overridden by the custom version
                List<DependentLibrary> inheritLibraryList = new ArrayList<>(Arrays.asList(librariesOrEmpty(inheritsVer)));
                outer_loop:
                for(DependentLibrary library : librariesOrEmpty(customVer)){
                    // Clean libraries overridden by the custom version
                    String libName = library.name.substring(0, library.name.lastIndexOf(":"));

                    for(DependentLibrary inheritLibrary : inheritLibraryList) {
                        String inheritLibName = inheritLibrary.name.substring(0, inheritLibrary.name.lastIndexOf(":"));

                        if(libName.equals(inheritLibName)){
                            System.out.println("Library " + libName + ": Replaced version " +
                                    libName.substring(libName.lastIndexOf(":") + 1) + " with " +
                                    inheritLibName.substring(inheritLibName.lastIndexOf(":") + 1));

                            // Remove the library , superseded by the overriding libs
                            inheritLibraryList.remove(inheritLibrary);
                            continue outer_loop;
                        }
                    }
                }

                // Fuse libraries
                inheritLibraryList.addAll(Arrays.asList(librariesOrEmpty(customVer)));
                inheritsVer.libraries = inheritLibraryList.toArray(new DependentLibrary[0]);
                preProcessLibraries(inheritsVer.libraries);

                // Inheriting Minecraft 1.13+ with append custom args
                if (inheritsVer.arguments != null && customVer.arguments != null
                        && inheritsVer.arguments.game != null && customVer.arguments.game != null) {
                    List totalArgList = new ArrayList();
                    totalArgList.addAll(Arrays.asList(inheritsVer.arguments.game));
                    
                    int nskip = 0;
                    for (int i = 0; i < customVer.arguments.game.length; i++) {
                        if (nskip > 0) {
                            nskip--;
                            continue;
                        }
                        
                        Object perCustomArg = customVer.arguments.game[i];
                        if (perCustomArg instanceof String) {
                            String perCustomArgStr = (String) perCustomArg;
                            // Check if there is a duplicate argument on combine
                            if (perCustomArgStr.startsWith("--") && totalArgList.contains(perCustomArgStr)) {
                                perCustomArg = customVer.arguments.game[i + 1];
                                if (perCustomArg instanceof String) {
                                    perCustomArgStr = (String) perCustomArg;
                                    // If the next is argument value, skip it
                                    if (!perCustomArgStr.startsWith("--")) {
                                        nskip++;
                                    }
                                }
                            } else {
                                totalArgList.add(perCustomArgStr);
                            }
                        } else if (!totalArgList.contains(perCustomArg)) {
                            totalArgList.add(perCustomArg);
                        }
                    }

                    inheritsVer.arguments.game = totalArgList.toArray(new Object[0]);
                }

                return inheritsVer;
            }
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // Prevent NullPointerException
    private static void insertSafety(JMinecraftVersionList.Version targetVer, JMinecraftVersionList.Version fromVer, String... keyArr) {
        for (String key : keyArr) {
            Object value = null;
            try {
                Field fieldA = fromVer.getClass().getField(key);
                value = fieldA.get(fromVer);
                if (((value instanceof String) && !((String) value).isEmpty()) || value != null) {
                    Field fieldB = targetVer.getClass().getField(key);
                    fieldB.set(targetVer, value);
                }
            } catch (Throwable th) {
                System.err.println("Unable to insert " + key + "=" + value);
                th.printStackTrace();
            }
        }
    }
    
    public static String convertStream(InputStream inputStream) throws IOException {
        return convertStream(inputStream, Charset.forName("UTF-8"));
    }
    
    public static String convertStream(InputStream inputStream, Charset charset) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = inputStream.read(buf))!=-1) {
            out += new String(buf,0,len,charset);
        }
        return out;
    }

    public static void copy(final InputStream input, final OutputStream output) throws IOException {
        final byte[] buffer = new byte[8192];
        int n = 0;
        while ((n = input.read(buffer)) != -1) {
            output.write(buffer, 0, n);
        }
    }

    public static File lastFileModified(String dir) {
        File fl = new File(dir);

        File[] files = fl.listFiles(new FileFilter() {
                public boolean accept(File file) {
                    return file.isFile();
                }
            });

        long lastMod = Long.MIN_VALUE;
        File choice = null;
        for (File file : files) {
            if (file.lastModified() > lastMod) {
                choice = file;
                lastMod = file.lastModified();
            }
        }

        return choice;
    }

    public static String read(InputStream is) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = is.read(buf))!=-1) {
            out += new String(buf,0,len);
        }
        return out;
    }

    public static String read(String path) throws IOException {
        return read(new FileInputStream(path));
    }

    public static void write(String path, byte[] content) throws IOException
    {
        File outPath = new File(path);
        outPath.getParentFile().mkdirs();
        outPath.createNewFile();

        BufferedOutputStream fos = new BufferedOutputStream(new FileOutputStream(path));
        fos.write(content, 0, content.length);
        fos.close();
    }

    public static void write(String path, String content) throws IOException {
        write(path, content.getBytes());
    }
}

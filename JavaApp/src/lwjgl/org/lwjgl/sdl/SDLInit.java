/*
 * iOS SDLInit 自定义 stub 实现（参照 iOS 自定义 GLFW 的模式）。
 *
 * 背景：LWJGL 原始的 SDLInit.class 中所有 SDL_Init / SDL_Quit 等方法都通过
 * org.lwjgl.system.JNI.invokeXxx 调用原生 SDL3 函数。在 iOS 上没有 libSDL3.dylib，
 * 即使 SDLDummyLibrary 返回 0 函数指针，JNI.invokeZ(0, 0) 仍可能导致原生崩溃。
 *
 * 参照 Android feat/lwjgl3ify-sdl-support 分支：Android 真正打包 libSDL3.so 并
 * 通过 bytehook 拦截 SDL_InitSubSystem 触发 SDL 输入转发。iOS 端不打包 SDL3，
 * 而是将 SDLInit 的所有方法替换为纯 Java stub，返回安全默认值，让 MC 认为 SDL
 * 已初始化但实际不执行任何原生操作。MC 继续使用现有的 GLFW 路径渲染和接收输入。
 *
 * 此类覆盖 LWJGL jar 中的 org.lwjgl.sdl.SDLInit（Makefile 中 JavaApp/src/lwjgl/
 * 编译后的 .class 在 jar 解压后复制，覆盖 jar 中的同名类）。
 *
 * 注意：必须保留与原类完全相同的 public API（常量和方法签名），
 * 否则引用这些 API 的其他 SDL 绑定类（SDLEvents/SDLGamepad 等）将无法编译。
 */
package org.lwjgl.sdl;

import java.nio.ByteBuffer;

public class SDLInit {

    // ===== SDL_INIT_* 子系统标志（与原生 SDL3 头文件一致） =====
    public static final int SDL_INIT_AUDIO    = 0x10;     // 16
    public static final int SDL_INIT_VIDEO    = 0x20;     // 32
    public static final int SDL_INIT_JOYSTICK = 0x200;    // 512
    public static final int SDL_INIT_HAPTIC   = 0x1000;   // 4096
    public static final int SDL_INIT_GAMEPAD  = 0x2000;   // 8192
    public static final int SDL_INIT_EVENTS   = 0x4000;   // 16384
    public static final int SDL_INIT_SENSOR   = 0x8000;   // 32768
    public static final int SDL_INIT_CAMERA   = 0x10000;  // 65536

    // ===== SDL_APP_* 退出码 =====
    public static final int SDL_APP_CONTINUE = 0;
    public static final int SDL_APP_SUCCESS  = 1;
    public static final int SDL_APP_FAILURE  = 2;

    // ===== SDL_PROP_APP_METADATA_*_STRING 属性键 =====
    public static final String SDL_PROP_APP_METADATA_NAME_STRING       = "SDL.app.metadata.name";
    public static final String SDL_PROP_APP_METADATA_VERSION_STRING    = "SDL.app.metadata.version";
    public static final String SDL_PROP_APP_METADATA_IDENTIFIER_STRING = "SDL.app.metadata.identifier";
    public static final String SDL_PROP_APP_METADATA_CREATOR_STRING    = "SDL.app.metadata.creator";
    public static final String SDL_PROP_APP_METADATA_COPYRIGHT_STRING  = "SDL.app.metadata.copyright";
    public static final String SDL_PROP_APP_METADATA_URL_STRING        = "SDL.app.metadata.url";
    public static final String SDL_PROP_APP_METADATA_TYPE_STRING       = "SDL.app.metadata.type";

    protected SDLInit() {
        throw new UnsupportedOperationException();
    }

    // ===== 初始化 / 卸载 =====

    /**
     * iOS stub：假装 SDL 初始化成功，但实际不执行任何操作。
     * MC 继续使用现有的 GLFW 路径渲染和接收输入。
     */
    public static boolean SDL_Init(int flags) {
        return true;
    }

    /**
     * iOS stub：假装子系统初始化成功。
     */
    public static boolean SDL_InitSubSystem(int flags) {
        return true;
    }

    /**
     * iOS stub：无操作。
     */
    public static void SDL_QuitSubSystem(int flags) {
        // 空实现
    }

    /**
     * iOS stub：返回请求的标志，假装所有请求的子系统都已初始化。
     * 这样 MC 检查 WasInit 时认为 SDL 已就绪，不会重复调用 SDL_Init。
     */
    public static int SDL_WasInit(int flags) {
        return flags;
    }

    /**
     * iOS stub：无操作。
     */
    public static void SDL_Quit() {
        // 空实现
    }

    // ===== 主线程相关 =====

    /**
     * iOS stub：Java 端总是在主线程上运行（从 MC 的视角）。
     */
    public static boolean SDL_IsMainThread() {
        return true;
    }

    /**
     * iOS stub：假装回调已成功调度到主线程，但实际不调用回调。
     * 返回 true 防止 MC 因调度失败而 abort。
     */
    public static boolean nSDL_RunOnMainThread(long callback, long userdata, boolean pushEvent) {
        return true;
    }

    /**
     * iOS stub：假装回调已成功调度到主线程。
     */
    public static boolean SDL_RunOnMainThread(SDL_MainThreadCallbackI callback, long userdata, boolean pushEvent) {
        return true;
    }

    // ===== 应用元数据 =====

    /**
     * iOS stub：假装元数据设置成功。
     */
    public static boolean nSDL_SetAppMetadata(long name, long version, long identifier) {
        return true;
    }

    /**
     * iOS stub：假装元数据设置成功。
     */
    public static boolean SDL_SetAppMetadata(ByteBuffer name, ByteBuffer version, ByteBuffer identifier) {
        return true;
    }

    /**
     * iOS stub：假装元数据设置成功。
     */
    public static boolean SDL_SetAppMetadata(CharSequence name, CharSequence version, CharSequence identifier) {
        return true;
    }

    /**
     * iOS stub：假装元数据属性设置成功。
     */
    public static boolean nSDL_SetAppMetadataProperty(long name, long value) {
        return true;
    }

    /**
     * iOS stub：假装元数据属性设置成功。
     */
    public static boolean SDL_SetAppMetadataProperty(ByteBuffer name, ByteBuffer value) {
        return true;
    }

    /**
     * iOS stub：假装元数据属性设置成功。
     */
    public static boolean SDL_SetAppMetadataProperty(CharSequence name, CharSequence value) {
        return true;
    }

    /**
     * iOS stub：返回 0（空指针），表示该属性未设置。
     * 调用方 SDL_GetAppMetadataProperty(ByteBuffer) 会用 memUTF8Safe(0) 返回 null。
     */
    public static long nSDL_GetAppMetadataProperty(long name) {
        return 0L;
    }

    /**
     * iOS stub：返回 null，表示该属性未设置。
     */
    public static String SDL_GetAppMetadataProperty(ByteBuffer name) {
        return null;
    }

    /**
     * iOS stub：返回 null，表示该属性未设置。
     */
    public static String SDL_GetAppMetadataProperty(CharSequence name) {
        return null;
    }
}

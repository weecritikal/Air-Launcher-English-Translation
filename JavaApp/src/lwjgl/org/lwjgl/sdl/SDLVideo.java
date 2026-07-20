/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS SDL3 视频窗口适配（覆盖 LWJGL 3.4.1 标准 SDLVideo.class）。
 *
 * 背景：
 *   MC 26.3-snapshot-4+ 使用 SDL3 替代 GLFW。MC 调用 SDL_CreateWindow
 *   创建窗口时，SDL3 UIKit 后端默认会创建新的 UIWindowScene，与启动器已有的
 *   GameSurfaceView（含 CAMetalLayer）冲突，导致 SDL_CreateWindow 阻塞
 *   或创建的窗口无法渲染到启动器的 surface。
 *
 * 解决方案：
 *   拦截 SDL_CreateWindow 调用，转交给 native 函数
 *   UIKit.sdlCreateWindowWithScene() 处理。该 native 函数：
 *     1. 获取启动器的 UIWindowScene 指针
 *     2. 通过 dlsym 获取 SDL3 的 Properties API 函数指针
 *     3. 创建 properties，设置 windowscene/metal/flags 属性
 *     4. 调用 SDL_CreateWindowWithProperties(props)
 *     5. 若失败，回退到标准 SDL_CreateWindow
 *
 *   这样 SDL3 UIKit 后端会复用启动器的 UIWindowScene，在其中创建 SDL
 *   专用的 UIView（含 CAMetalLayer 子层），渲染到启动器的窗口中。
 *
 * 设计说明：
 *   - 此类完整替换 LWJGL 3.4.1 的 SDLVideo.class：
 *       1) SDL_CreateWindow / SDL_CreateWindowWithProperties 拦截走 native helper；
 *       2) 其他 SDL3 视频 API（SDL_GL_CreateContext、SDL_GL_MakeCurrent、
 *          SDL_GL_SwapWindow、SDL_DestroyWindow 等）通过 Functions 表
 *          委托给 libSDL3.dylib；
 *       3) 所有常量（约 130 个）从 LWJGL 3.4.1 SDLVideo.class 完整复制，
 *          避免 MC 引用常量时出现 NoSuchFieldError。
 *   - 不使用反射（避免覆盖类自身递归调用），所有 SDL3 native 调用都通过
 *     LWJGL 的 JNI invoke/call helper 间接调用 libffi。
 *
 * 反射递归问题（已修复）：
 *   早期版本使用 Class.forName("org.lwjgl.sdl.SDLVideo") 反射调用
 *   SDL_CreateWindowWithProperties，但由于本类就是 org.lwjgl.sdl.SDLVideo
 *   的覆盖类，Class.forName 返回本类自身，导致 invoke 时无限递归栈溢出。
 *   现改为通过 native helper 直接调用 SDL3 函数，完全绕开反射。
 */
package org.lwjgl.sdl;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;

import net.kdt.pojavlaunch.uikit.UIKit;

import static org.lwjgl.system.APIUtil.*;
import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.MemoryUtil.*;

public final class SDLVideo {

    static {
        System.out.println("[SDLVideo] class loaded (Amethyst override, commit " + "diag-v1" + ")");
        System.out.println("[SDLVideo] classloader=" + SDLVideo.class.getClassLoader());
        System.out.println("[SDLVideo] protection domain=" + SDLVideo.class.getProtectionDomain());
        // 打印调用栈，确认是谁触发了类加载
        new Throwable("[SDLVideo] class init stack trace").printStackTrace(System.out);
    }

    // ============================================================================
    // 常量（完整复制自 LWJGL 3.4.1 SDLVideo.class，避免 MC 引用时 NoSuchFieldError）
    // ============================================================================

    public static final String SDL_PROP_GLOBAL_VIDEO_WAYLAND_WL_DISPLAY_POINTER = "SDL.video.wayland.wl_display";
    public static final int SDL_SYSTEM_THEME_UNKNOWN = 0;
    public static final int SDL_SYSTEM_THEME_LIGHT = 1;
    public static final int SDL_SYSTEM_THEME_DARK = 2;
    public static final int SDL_ORIENTATION_UNKNOWN = 0;
    public static final int SDL_ORIENTATION_LANDSCAPE = 1;
    public static final int SDL_ORIENTATION_LANDSCAPE_FLIPPED = 2;
    public static final int SDL_ORIENTATION_PORTRAIT = 3;
    public static final int SDL_ORIENTATION_PORTRAIT_FLIPPED = 4;
    public static final long SDL_WINDOW_FULLSCREEN = 1L;
    public static final long SDL_WINDOW_OPENGL = 2L;
    public static final long SDL_WINDOW_OCCLUDED = 4L;
    public static final long SDL_WINDOW_HIDDEN = 8L;
    public static final long SDL_WINDOW_BORDERLESS = 16L;
    public static final long SDL_WINDOW_RESIZABLE = 32L;
    public static final long SDL_WINDOW_MINIMIZED = 64L;
    public static final long SDL_WINDOW_MAXIMIZED = 128L;
    public static final long SDL_WINDOW_MOUSE_GRABBED = 256L;
    public static final long SDL_WINDOW_INPUT_FOCUS = 512L;
    public static final long SDL_WINDOW_MOUSE_FOCUS = 1024L;
    public static final long SDL_WINDOW_EXTERNAL = 2048L;
    public static final long SDL_WINDOW_MODAL = 4096L;
    public static final long SDL_WINDOW_HIGH_PIXEL_DENSITY = 8192L;
    public static final long SDL_WINDOW_MOUSE_CAPTURE = 16384L;
    public static final long SDL_WINDOW_MOUSE_RELATIVE_MODE = 32768L;
    public static final long SDL_WINDOW_ALWAYS_ON_TOP = 65536L;
    public static final long SDL_WINDOW_UTILITY = 131072L;
    public static final long SDL_WINDOW_TOOLTIP = 262144L;
    public static final long SDL_WINDOW_POPUP_MENU = 524288L;
    public static final long SDL_WINDOW_KEYBOARD_GRABBED = 1048576L;
    public static final long SDL_WINDOW_FILL_DOCUMENT = 2097152L;
    public static final long SDL_WINDOW_VULKAN = 268435456L;
    public static final long SDL_WINDOW_METAL = 536870912L;
    public static final long SDL_WINDOW_TRANSPARENT = 1073741824L;
    public static final long SDL_WINDOW_NOT_FOCUSABLE = 2147483648L;
    public static final int SDL_WINDOWPOS_UNDEFINED_MASK = 536805376;
    public static final int SDL_WINDOWPOS_UNDEFINED = SDL_WINDOWPOS_UNDEFINED_MASK;
    public static final int SDL_WINDOWPOS_CENTERED_MASK = 805240832;
    public static final int SDL_WINDOWPOS_CENTERED = SDL_WINDOWPOS_CENTERED_MASK;
    public static final int SDL_FLASH_CANCEL = 0;
    public static final int SDL_FLASH_BRIEFLY = 1;
    public static final int SDL_FLASH_UNTIL_FOCUSED = 2;
    public static final int SDL_PROGRESS_STATE_INVALID = -1;
    public static final int SDL_PROGRESS_STATE_NONE = 0;
    public static final int SDL_PROGRESS_STATE_INDETERMINATE = 1;
    public static final int SDL_PROGRESS_STATE_NORMAL = 2;
    public static final int SDL_PROGRESS_STATE_PAUSED = 3;
    public static final int SDL_PROGRESS_STATE_ERROR = 4;
    public static final int SDL_GL_RED_SIZE = 0;
    public static final int SDL_GL_GREEN_SIZE = 1;
    public static final int SDL_GL_BLUE_SIZE = 2;
    public static final int SDL_GL_ALPHA_SIZE = 3;
    public static final int SDL_GL_BUFFER_SIZE = 4;
    public static final int SDL_GL_DOUBLEBUFFER = 5;
    public static final int SDL_GL_DEPTH_SIZE = 6;
    public static final int SDL_GL_STENCIL_SIZE = 7;
    public static final int SDL_GL_ACCUM_RED_SIZE = 8;
    public static final int SDL_GL_ACCUM_GREEN_SIZE = 9;
    public static final int SDL_GL_ACCUM_BLUE_SIZE = 10;
    public static final int SDL_GL_ACCUM_ALPHA_SIZE = 11;
    public static final int SDL_GL_STEREO = 12;
    public static final int SDL_GL_MULTISAMPLEBUFFERS = 13;
    public static final int SDL_GL_MULTISAMPLESAMPLES = 14;
    public static final int SDL_GL_ACCELERATED_VISUAL = 15;
    public static final int SDL_GL_RETAINED_BACKING = 16;
    public static final int SDL_GL_CONTEXT_MAJOR_VERSION = 17;
    public static final int SDL_GL_CONTEXT_MINOR_VERSION = 18;
    public static final int SDL_GL_CONTEXT_FLAGS = 19;
    public static final int SDL_GL_CONTEXT_PROFILE_MASK = 20;
    public static final int SDL_GL_SHARE_WITH_CURRENT_CONTEXT = 21;
    public static final int SDL_GL_FRAMEBUFFER_SRGB_CAPABLE = 22;
    public static final int SDL_GL_CONTEXT_RELEASE_BEHAVIOR = 23;
    public static final int SDL_GL_CONTEXT_RESET_NOTIFICATION = 24;
    public static final int SDL_GL_CONTEXT_NO_ERROR = 25;
    public static final int SDL_GL_FLOATBUFFERS = 26;
    public static final int SDL_GL_EGL_PLATFORM = 27;
    public static final int SDL_GL_CONTEXT_PROFILE_CORE = 1;
    public static final int SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = 2;
    public static final int SDL_GL_CONTEXT_PROFILE_ES = 4;
    public static final int SDL_GL_CONTEXT_DEBUG_FLAG = 1;
    public static final int SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG = 2;
    public static final int SDL_GL_CONTEXT_ROBUST_ACCESS_FLAG = 4;
    public static final int SDL_GL_CONTEXT_RESET_ISOLATION_FLAG = 8;
    public static final int SDL_GL_CONTEXT_RELEASE_BEHAVIOR_NONE = 0;
    public static final int SDL_GL_CONTEXT_RELEASE_BEHAVIOR_FLUSH = 1;
    public static final int SDL_GL_CONTEXT_RESET_NO_NOTIFICATION = 0;
    public static final int SDL_GL_CONTEXT_RESET_LOSE_CONTEXT = 1;

    public static final String SDL_PROP_DISPLAY_HDR_ENABLED_BOOLEAN = "SDL.display.HDR_enabled";
    public static final String SDL_PROP_DISPLAY_KMSDRM_PANEL_ORIENTATION_NUMBER = "SDL.display.KMSDRM.panel_orientation";
    public static final String SDL_PROP_DISPLAY_WAYLAND_WL_OUTPUT_POINTER = "SDL.display.wayland.wl_output";
    public static final String SDL_PROP_DISPLAY_WINDOWS_HMONITOR_POINTER = "SDL.display.windows.hmonitor";
    public static final String SDL_PROP_WINDOW_CREATE_ALWAYS_ON_TOP_BOOLEAN = "SDL.window.create.always_on_top";
    public static final String SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN = "SDL.window.create.borderless";
    public static final String SDL_PROP_WINDOW_CREATE_CONSTRAIN_POPUP_BOOLEAN = "SDL.window.create.constrain_popup";
    public static final String SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN = "SDL.window.create.focusable";
    public static final String SDL_PROP_WINDOW_CREATE_EXTERNAL_GRAPHICS_CONTEXT_BOOLEAN = "SDL.window.create.external_graphics_context";
    public static final String SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER = "SDL.window.create.flags";
    public static final String SDL_PROP_WINDOW_CREATE_FULLSCREEN_BOOLEAN = "SDL.window.create.fullscreen";
    public static final String SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER = "SDL.window.create.height";
    public static final String SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN = "SDL.window.create.hidden";
    public static final String SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN = "SDL.window.create.high_pixel_density";
    public static final String SDL_PROP_WINDOW_CREATE_MAXIMIZED_BOOLEAN = "SDL.window.create.maximized";
    public static final String SDL_PROP_WINDOW_CREATE_MENU_BOOLEAN = "SDL.window.create.menu";
    public static final String SDL_PROP_WINDOW_CREATE_METAL_BOOLEAN = "SDL.window.create.metal";
    public static final String SDL_PROP_WINDOW_CREATE_MINIMIZED_BOOLEAN = "SDL.window.create.minimized";
    public static final String SDL_PROP_WINDOW_CREATE_MODAL_BOOLEAN = "SDL.window.create.modal";
    public static final String SDL_PROP_WINDOW_CREATE_MOUSE_GRABBED_BOOLEAN = "SDL.window.create.mouse_grab";
    public static final String SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN = "SDL.window.create.opengl";
    public static final String SDL_PROP_WINDOW_CREATE_PARENT_POINTER = "SDL.window.create.parent";
    public static final String SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN = "SDL.window.create.resizable";
    public static final String SDL_PROP_WINDOW_CREATE_TITLE_STRING = "SDL.window.create.title";
    public static final String SDL_PROP_WINDOW_CREATE_TRANSPARENT_BOOLEAN = "SDL.window.create.transparent";
    public static final String SDL_PROP_WINDOW_CREATE_TOOLTIP_BOOLEAN = "SDL.window.create.tooltip";
    public static final String SDL_PROP_WINDOW_CREATE_UTILITY_BOOLEAN = "SDL.window.create.utility";
    public static final String SDL_PROP_WINDOW_CREATE_VULKAN_BOOLEAN = "SDL.window.create.vulkan";
    public static final String SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER = "SDL.window.create.width";
    public static final String SDL_PROP_WINDOW_CREATE_X_NUMBER = "SDL.window.create.x";
    public static final String SDL_PROP_WINDOW_CREATE_Y_NUMBER = "SDL.window.create.y";
    public static final String SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER = "SDL.window.create.cocoa.window";
    public static final String SDL_PROP_WINDOW_CREATE_COCOA_VIEW_POINTER = "SDL.window.create.cocoa.view";
    public static final String SDL_PROP_WINDOW_CREATE_WINDOWSCENE_POINTER = "SDL.window.create.uikit.windowscene";
    public static final String SDL_PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM_BOOLEAN = "SDL.window.create.wayland.surface_role_custom";
    public static final String SDL_PROP_WINDOW_CREATE_WAYLAND_CREATE_EGL_WINDOW_BOOLEAN = "SDL.window.create.wayland.create_egl_window";
    public static final String SDL_PROP_WINDOW_CREATE_WAYLAND_WL_SURFACE_POINTER = "SDL.window.create.wayland.wl_surface";
    public static final String SDL_PROP_WINDOW_CREATE_WIN32_HWND_POINTER = "SDL.window.create.win32.hwnd";
    public static final String SDL_PROP_WINDOW_CREATE_WIN32_PIXEL_FORMAT_HWND_POINTER = "SDL.window.create.win32.pixel_format_hwnd";
    public static final String SDL_PROP_WINDOW_CREATE_X11_WINDOW_NUMBER = "SDL.window.create.x11.window";
    public static final String SDL_PROP_WINDOW_CREATE_EMSCRIPTEN_CANVAS_ID_STRING = "SDL.window.create.emscripten.canvas_id";
    public static final String SDL_PROP_WINDOW_CREATE_EMSCRIPTEN_KEYBOARD_ELEMENT_STRING = "SDL.window.create.emscripten.keyboard_element";
    public static final String SDL_PROP_WINDOW_SHAPE_POINTER = "SDL.window.shape";
    public static final String SDL_PROP_WINDOW_HDR_ENABLED_BOOLEAN = "SDL.window.HDR_enabled";
    public static final String SDL_PROP_WINDOW_SDR_WHITE_LEVEL_FLOAT = "SDL.window.SDR_white_level";
    public static final String SDL_PROP_WINDOW_HDR_HEADROOM_FLOAT = "SDL.window.HDR_headroom";
    public static final String SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER = "SDL.window.android.window";
    public static final String SDL_PROP_WINDOW_ANDROID_SURFACE_POINTER = "SDL.window.android.surface";
    public static final String SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER = "SDL.window.uikit.window";
    public static final String SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER = "SDL.window.uikit.metal_view_tag";
    public static final String SDL_PROP_WINDOW_UIKIT_OPENGL_FRAMEBUFFER_NUMBER = "SDL.window.uikit.opengl.framebuffer";
    public static final String SDL_PROP_WINDOW_UIKIT_OPENGL_RENDERBUFFER_NUMBER = "SDL.window.uikit.opengl.renderbuffer";
    public static final String SDL_PROP_WINDOW_UIKIT_OPENGL_RESOLVE_FRAMEBUFFER_NUMBER = "SDL.window.uikit.opengl.resolve_framebuffer";
    public static final String SDL_PROP_WINDOW_KMSDRM_DEVICE_INDEX_NUMBER = "SDL.window.kmsdrm.dev_index";
    public static final String SDL_PROP_WINDOW_KMSDRM_DRM_FD_NUMBER = "SDL.window.kmsdrm.drm_fd";
    public static final String SDL_PROP_WINDOW_KMSDRM_GBM_DEVICE_POINTER = "SDL.window.kmsdrm.gbm_dev";
    public static final String SDL_PROP_WINDOW_COCOA_WINDOW_POINTER = "SDL.window.cocoa.window";
    public static final String SDL_PROP_WINDOW_COCOA_METAL_VIEW_TAG_NUMBER = "SDL.window.cocoa.metal_view_tag";
    public static final String SDL_PROP_WINDOW_OPENVR_OVERLAY_ID_NUMBER = "SDL.window.openvr.overlay_id";
    public static final String SDL_PROP_WINDOW_VIVANTE_DISPLAY_POINTER = "SDL.window.vivante.display";
    public static final String SDL_PROP_WINDOW_VIVANTE_WINDOW_POINTER = "SDL.window.vivante.window";
    public static final String SDL_PROP_WINDOW_VIVANTE_SURFACE_POINTER = "SDL.window.vivante.surface";
    public static final String SDL_PROP_WINDOW_WIN32_HWND_POINTER = "SDL.window.win32.hwnd";
    public static final String SDL_PROP_WINDOW_WIN32_HDC_POINTER = "SDL.window.win32.hdc";
    public static final String SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER = "SDL.window.win32.instance";
    public static final String SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = "SDL.window.wayland.display";
    public static final String SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = "SDL.window.wayland.surface";
    public static final String SDL_PROP_WINDOW_WAYLAND_VIEWPORT_POINTER = "SDL.window.wayland.viewport";
    public static final String SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER = "SDL.window.wayland.egl_window";
    public static final String SDL_PROP_WINDOW_WAYLAND_XDG_SURFACE_POINTER = "SDL.window.wayland.xdg_surface";
    public static final String SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER = "SDL.window.wayland.xdg_toplevel";
    public static final String SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_EXPORT_HANDLE_STRING = "SDL.window.wayland.xdg_toplevel_export_handle";
    public static final String SDL_PROP_WINDOW_WAYLAND_XDG_POPUP_POINTER = "SDL.window.wayland.xdg_popup";
    public static final String SDL_PROP_WINDOW_WAYLAND_XDG_POSITIONER_POINTER = "SDL.window.wayland.xdg_positioner";
    public static final String SDL_PROP_WINDOW_X11_DISPLAY_POINTER = "SDL.window.x11.display";
    public static final String SDL_PROP_WINDOW_X11_SCREEN_NUMBER = "SDL.window.x11.screen";
    public static final String SDL_PROP_WINDOW_X11_WINDOW_NUMBER = "SDL.window.x11.window";
    public static final String SDL_PROP_WINDOW_EMSCRIPTEN_CANVAS_ID_STRING = "SDL.window.emscripten.canvas_id";
    public static final String SDL_PROP_WINDOW_EMSCRIPTEN_KEYBOARD_ELEMENT_STRING = "SDL.window.emscripten.keyboard_element";
    public static final int SDL_WINDOW_SURFACE_VSYNC_DISABLED = 0;
    public static final int SDL_WINDOW_SURFACE_VSYNC_ADAPTIVE = -1;
    public static final int SDL_HITTEST_NORMAL = 0;
    public static final int SDL_HITTEST_DRAGGABLE = 1;
    public static final int SDL_HITTEST_RESIZE_TOPLEFT = 2;
    public static final int SDL_HITTEST_RESIZE_TOP = 3;
    public static final int SDL_HITTEST_RESIZE_TOPRIGHT = 4;
    public static final int SDL_HITTEST_RESIZE_RIGHT = 5;
    public static final int SDL_HITTEST_RESIZE_BOTTOMRIGHT = 6;
    public static final int SDL_HITTEST_RESIZE_BOTTOM = 7;
    public static final int SDL_HITTEST_RESIZE_BOTTOMLEFT = 8;
    public static final int SDL_HITTEST_RESIZE_LEFT = 9;

    // ============================================================================
    // SDL_CreateWindow 覆盖（iOS UIKit 适配核心）
    // ============================================================================

    /**
     * 拦截 SDL_CreateWindow 调用，转交 native helper 处理。
     *
     * native helper (UIKit.sdlCreateWindowWithScene) 会：
     *   1. 获取启动器的 UIWindowScene 指针
     *   2. 通过 dlsym 获取 SDL3 Properties API 函数指针
     *   3. 创建 properties，设置 windowscene/metal/flags
     *   4. 调用 SDL_CreateWindowWithProperties
     *   5. 失败则回退到标准 SDL_CreateWindow
     *
     * @param title 窗口标题（iOS UIKit 不使用，忽略）
     * @param w 窗口宽度
     * @param h 窗口高度
     * @param flags 窗口 flags
     * @return SDL_Window 指针（成功）或 0（失败）
     */
    public static long SDL_CreateWindow(CharSequence title, int w, int h, long flags) {
        return SDL_CreateWindow(title == null ? null : toByteBuffer(title), w, h, flags);
    }

    public static long SDL_CreateWindow(ByteBuffer title, int w, int h, long flags) {
        System.out.println("[SDLVideo] SDL_CreateWindow intercepted: w=" + w + " h=" + h + " flags=0x" + Long.toHexString(flags));

        long window = UIKit.sdlCreateWindowWithScene(w, h, flags);

        System.out.println("[SDLVideo] Window created: 0x" + Long.toHexString(window));
        if (window == 0) {
            System.out.println("[SDLVideo] FATAL: Window creation failed, MC will likely crash");
        }
        return window;
    }

    /**
     * 覆盖 SDL_CreateWindowWithProperties。
     *
     * MC 26.3-snapshot-4+ 可能用此方法创建窗口（而非 SDL_CreateWindow）。
     * 如果 MC 直接调用原始版本，SDL3 UIKit 后端会创建新 UIWindowScene 导致阻塞。
     *
     * 此覆盖忽略传入的 properties，转用我们的 native helper 创建窗口（复用启动器 UIWindowScene）。
     */
    public static long SDL_CreateWindowWithProperties(int props) {
        System.out.println("[SDLVideo] SDL_CreateWindowWithProperties intercepted: props=" + props);
        // 忽略传入的 props，用默认参数创建窗口
        // SDL_CreateWindowWithProperties 通常设置 width/height/flags 等，
        // 我们从 props 中无法轻易读取（需要 native 层 SDL_GetNumberProperty），
        // 所以用默认尺寸创建，后续 MC 会调用 SDL_SetWindowSize 调整
        long window = UIKit.sdlCreateWindowWithScene(0, 0, 0);
        System.out.println("[SDLVideo] SDL_CreateWindowWithProperties returned: 0x" + Long.toHexString(window));
        return window;
    }

    /// 辅助方法：CharSequence 转 ByteBuffer
    private static ByteBuffer toByteBuffer(CharSequence cs) {
        if (cs == null) return null;
        return org.lwjgl.system.MemoryUtil.memUTF8(cs);
    }

    // ============================================================================
    // SDL3 函数指针表（从 libSDL3.dylib 解析）
    // ============================================================================
    // 参照 GLFW.java 的 Functions 模式：通过 SDL.getLibrary() 获取 SharedLibrary，
    // 用 apiGetFunctionAddress 查找 SDL3 native 函数地址，再用 JNI.invoke*/call* helper 调用。
    //
    // 关键修复：原版 LWJGL 3.4.1 SDLVideo.class 被本覆盖类完整替换，所有方法都丢失。
    // MC 26.3-snapshot-4+ 调用 SDL_GL_CreateContext、SDL_GL_MakeCurrent、SDL_GL_SwapWindow
    // 等方法时会抛 NoSuchMethodError。此处补充所有 MC 启动链路必需的 SDL3 视频 API。
    private static final org.lwjgl.system.SharedLibrary SDL_LIB = SDL.getLibrary();

    public static final class Functions {
        private Functions() {}
        public static final long
        SDL_DestroyWindow = apiGetFunctionAddress(SDL_LIB, "SDL_DestroyWindow"),
        SDL_GetWindowID = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowID"),
        SDL_GetWindowFromID = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowFromID"),
        SDL_GetWindowFlags = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowFlags"),
        SDL_SetWindowTitle = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowTitle"),
        SDL_GetWindowTitle = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowTitle"),
        SDL_SetWindowPosition = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowPosition"),
        SDL_GetWindowPosition = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowPosition"),
        SDL_SetWindowSize = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowSize"),
        SDL_GetWindowSize = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowSize"),
        SDL_SetWindowBordered = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowBordered"),
        SDL_SetWindowResizable = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowResizable"),
        SDL_SetWindowAlwaysOnTop = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowAlwaysOnTop"),
        SDL_ShowWindow = apiGetFunctionAddress(SDL_LIB, "SDL_ShowWindow"),
        SDL_HideWindow = apiGetFunctionAddress(SDL_LIB, "SDL_HideWindow"),
        SDL_RaiseWindow = apiGetFunctionAddress(SDL_LIB, "SDL_RaiseWindow"),
        SDL_MaximizeWindow = apiGetFunctionAddress(SDL_LIB, "SDL_MaximizeWindow"),
        SDL_MinimizeWindow = apiGetFunctionAddress(SDL_LIB, "SDL_MinimizeWindow"),
        SDL_RestoreWindow = apiGetFunctionAddress(SDL_LIB, "SDL_RestoreWindow"),
        SDL_SetWindowFullscreen = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowFullscreen"),
        SDL_SyncWindow = apiGetFunctionAddress(SDL_LIB, "SDL_SyncWindow"),
        SDL_WindowHasSurface = apiGetFunctionAddress(SDL_LIB, "SDL_WindowHasSurface"),
        // MC 26.3-snapshot-4 Window.class 引用的额外方法（之前缺失，导致 NoSuchMethodError）
        SDL_GetPrimaryDisplay = apiGetFunctionAddress(SDL_LIB, "SDL_GetPrimaryDisplay"),
        SDL_GetCurrentVideoDriver = apiGetFunctionAddress(SDL_LIB, "SDL_GetCurrentVideoDriver"),
        SDL_GetDisplayForWindow = apiGetFunctionAddress(SDL_LIB, "SDL_GetDisplayForWindow"),
        SDL_GetCurrentDisplayMode = apiGetFunctionAddress(SDL_LIB, "SDL_GetCurrentDisplayMode"),
        SDL_GetClosestFullscreenDisplayMode = apiGetFunctionAddress(SDL_LIB, "SDL_GetClosestFullscreenDisplayMode"),
        SDL_GetWindowFullscreenMode = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowFullscreenMode"),
        SDL_SetWindowFullscreenMode = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowFullscreenMode"),
        SDL_GetWindowSizeInPixels = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowSizeInPixels"),
        SDL_GetWindowPixelDensity = apiGetFunctionAddress(SDL_LIB, "SDL_GetWindowPixelDensity"),
        SDL_SetWindowMinimumSize = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowMinimumSize"),
        SDL_SetWindowMaximumSize = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowMaximumSize"),
        SDL_SetWindowIcon = apiGetFunctionAddress(SDL_LIB, "SDL_SetWindowIcon"),
        SDL_ScreenSaverEnabled = apiGetFunctionAddress(SDL_LIB, "SDL_ScreenSaverEnabled"),
        SDL_EnableScreenSaver = apiGetFunctionAddress(SDL_LIB, "SDL_EnableScreenSaver"),
        SDL_DisableScreenSaver = apiGetFunctionAddress(SDL_LIB, "SDL_DisableScreenSaver"),
        SDL_GL_LoadLibrary = apiGetFunctionAddress(SDL_LIB, "SDL_GL_LoadLibrary"),
        SDL_GL_GetProcAddress = apiGetFunctionAddress(SDL_LIB, "SDL_GL_GetProcAddress"),
        SDL_GL_UnloadLibrary = apiGetFunctionAddress(SDL_LIB, "SDL_GL_UnloadLibrary"),
        SDL_GL_ExtensionSupported = apiGetFunctionAddress(SDL_LIB, "SDL_GL_ExtensionSupported"),
        SDL_GL_ResetAttributes = apiGetFunctionAddress(SDL_LIB, "SDL_GL_ResetAttributes"),
        SDL_GL_SetAttribute = apiGetFunctionAddress(SDL_LIB, "SDL_GL_SetAttribute"),
        SDL_GL_GetAttribute = apiGetFunctionAddress(SDL_LIB, "SDL_GL_GetAttribute"),
        SDL_GL_CreateContext = apiGetFunctionAddress(SDL_LIB, "SDL_GL_CreateContext"),
        SDL_GL_MakeCurrent = apiGetFunctionAddress(SDL_LIB, "SDL_GL_MakeCurrent"),
        SDL_GL_GetCurrentWindow = apiGetFunctionAddress(SDL_LIB, "SDL_GL_GetCurrentWindow"),
        SDL_GL_GetCurrentContext = apiGetFunctionAddress(SDL_LIB, "SDL_GL_GetCurrentContext"),
        SDL_GL_SetSwapInterval = apiGetFunctionAddress(SDL_LIB, "SDL_GL_SetSwapInterval"),
        SDL_GL_GetSwapInterval = apiGetFunctionAddress(SDL_LIB, "SDL_GL_GetSwapInterval"),
        SDL_GL_SwapWindow = apiGetFunctionAddress(SDL_LIB, "SDL_GL_SwapWindow"),
        SDL_GL_DestroyContext = apiGetFunctionAddress(SDL_LIB, "SDL_GL_DestroyContext");
    }

    // ============================================================================
    // SDL3 视频 API 实现（委托给 libSDL3.dylib）
    // ============================================================================

    // --- 窗口生命周期 ---

    public static int SDL_GetWindowID(long window) {
        return callPI(window, Functions.SDL_GetWindowID);
    }

    public static long SDL_GetWindowFromID(int id) {
        return callP(id, Functions.SDL_GetWindowFromID);
    }

    public static long SDL_GetWindowFlags(long window) {
        // SDL3 返回 Uint32，原版 LWJGL 用 invokePJ(long, long)→long 直接返回
        return invokePJ(window, Functions.SDL_GetWindowFlags);
    }

    public static boolean SDL_SetWindowTitle(long window, ByteBuffer title) {
        return callPPZ(window, memAddress(title), Functions.SDL_SetWindowTitle);
    }

    public static boolean SDL_SetWindowTitle(long window, CharSequence title) {
        return SDL_SetWindowTitle(window, toByteBuffer(title));
    }

    public static String SDL_GetWindowTitle(long window) {
        // SDL_GetWindowTitle 返回 const char* 指针（SDL 内部管理，不需释放）
        long ptr = callPP(window, Functions.SDL_GetWindowTitle);
        return memUTF8Safe(ptr);
    }

    public static boolean SDL_SetWindowPosition(long window, int x, int y) {
        // 需 invokePZ(long, int, int, long) — callPZ 无此重载
        return invokePZ(window, x, y, Functions.SDL_SetWindowPosition);
    }

    public static boolean SDL_GetWindowPosition(long window, IntBuffer x, IntBuffer y) {
        // 需 invokePPPZ(long, long, long, long) — callPPZ 无 (long,long,long,long) 重载
        return invokePPPZ(window, memAddress(x), memAddress(y), Functions.SDL_GetWindowPosition);
    }

    public static boolean SDL_SetWindowSize(long window, int w, int h) {
        // 需 invokePZ(long, int, int, long) — callPZ 无此重载
        return invokePZ(window, w, h, Functions.SDL_SetWindowSize);
    }

    public static boolean SDL_GetWindowSize(long window, IntBuffer w, IntBuffer h) {
        // 需 invokePPPZ(long, long, long, long) — callPPZ 无 (long,long,long,long) 重载
        return invokePPPZ(window, memAddress(w), memAddress(h), Functions.SDL_GetWindowSize);
    }

    public static boolean SDL_SetWindowBordered(long window, boolean bordered) {
        // 需 invokePZ(long, boolean, long) — callPZ 无此重载
        return invokePZ(window, bordered, Functions.SDL_SetWindowBordered);
    }

    public static boolean SDL_SetWindowResizable(long window, boolean resizable) {
        return invokePZ(window, resizable, Functions.SDL_SetWindowResizable);
    }

    public static boolean SDL_SetWindowAlwaysOnTop(long window, boolean on_top) {
        return invokePZ(window, on_top, Functions.SDL_SetWindowAlwaysOnTop);
    }

    public static boolean SDL_ShowWindow(long window) {
        return callPZ(window, Functions.SDL_ShowWindow);
    }

    public static boolean SDL_HideWindow(long window) {
        return callPZ(window, Functions.SDL_HideWindow);
    }

    public static boolean SDL_RaiseWindow(long window) {
        return callPZ(window, Functions.SDL_RaiseWindow);
    }

    public static boolean SDL_MaximizeWindow(long window) {
        return callPZ(window, Functions.SDL_MaximizeWindow);
    }

    public static boolean SDL_MinimizeWindow(long window) {
        return callPZ(window, Functions.SDL_MinimizeWindow);
    }

    public static boolean SDL_RestoreWindow(long window) {
        return callPZ(window, Functions.SDL_RestoreWindow);
    }

    public static boolean SDL_SetWindowFullscreen(long window, boolean fullscreen) {
        // 需 invokePZ(long, boolean, long) — callPZ 无此重载
        return invokePZ(window, fullscreen, Functions.SDL_SetWindowFullscreen);
    }

    public static boolean SDL_SyncWindow(long window) {
        return callPZ(window, Functions.SDL_SyncWindow);
    }

    public static boolean SDL_WindowHasSurface(long window) {
        return callPZ(window, Functions.SDL_WindowHasSurface);
    }

    public static void SDL_DestroyWindow(long window) {
        // SDL3 SDL_DestroyWindow 返回 void，使用 invokePV(long, long)→void
        invokePV(window, Functions.SDL_DestroyWindow);
    }

    // --- MC 26.3-snapshot-4 Window.class 引用的额外方法 ---
    // 这些方法之前缺失，导致 MC 调用 SDL_GetPrimaryDisplay 时抛 NoSuchMethodError，
    // SDLVideo 类初始化失败，整个 SDL3 启动流程卡住。

    /// 返回主显示器 ID（SDL3 SDL_GetPrimaryDisplay 返回 SDL_DisplayID = Uint32）
    public static int SDL_GetPrimaryDisplay() {
        return callI(Functions.SDL_GetPrimaryDisplay);
    }

    /// 返回当前视频驱动名称（const char*），null 表示无驱动
    public static String SDL_GetCurrentVideoDriver() {
        long ptr = callP(Functions.SDL_GetCurrentVideoDriver);
        return memUTF8Safe(ptr);
    }

    /// 返回窗口所在的显示器 ID
    public static int SDL_GetDisplayForWindow(long window) {
        return callPI(window, Functions.SDL_GetDisplayForWindow);
    }

    /// 返回指定显示器的当前显示模式（SDL_DisplayMode* 指针，由 SDL 内部管理）
    public static long SDL_GetCurrentDisplayMode(int displayID) {
        return callP(displayID, Functions.SDL_GetCurrentDisplayMode);
    }

    /// 查找最接近的 fullscreen 显示模式
    ///
    /// 注意：原版 LWJGL 3.4.1 调用 JNI.invokePZ(IIIFZJJ)Z，但本项目的 JNI.class
    /// （来自 lwjgl-system.jar）未导出此 7 参数重载，运行时会抛 NoSuchMethodError。
    /// 本项目从窗口模式启动（SurfaceViewController 已配置 CAMetalLayer drawableSize），
    /// 此方法仅在 MC 主动切换 fullscreen 时才会被调用。stub 返回 false 表示
    /// "未找到匹配的 fullscreen 模式"，MC 会回退到默认 fullscreen 模式或保持窗口模式，
    /// 不影响启动流程。如未来需要真正的 fullscreen 模式查找，需在 native 层实现
    /// 一个 helper（通过 dlsym 调用 SDL_GetClosestFullscreenDisplayMode）。
    public static boolean SDL_GetClosestFullscreenDisplayMode(int displayID, int w, int h, float refreshRate, boolean includeHighDensityModes, long outMode) {
        return false;
    }

    /// 返回窗口的 fullscreen 模式（SDL_DisplayMode* 指针）
    public static long SDL_GetWindowFullscreenMode(long window) {
        return callPP(window, Functions.SDL_GetWindowFullscreenMode);
    }

    /// 设置窗口的 fullscreen 模式
    public static boolean SDL_SetWindowFullscreenMode(long window, long mode) {
        return callPPZ(window, mode, Functions.SDL_SetWindowFullscreenMode);
    }

    /// 获取窗口的像素大小
    public static boolean SDL_GetWindowSizeInPixels(long window, IntBuffer w, IntBuffer h) {
        return invokePPPZ(window, memAddress(w), memAddress(h), Functions.SDL_GetWindowSizeInPixels);
    }

    /// 返回窗口的像素密度（float）
    public static float SDL_GetWindowPixelDensity(long window) {
        // SDL3 返回 float，LWJGL invokePF(long, long)→float
        return invokePF(window, Functions.SDL_GetWindowPixelDensity);
    }

    /// 设置窗口最小尺寸
    public static boolean SDL_SetWindowMinimumSize(long window, int minW, int minH) {
        return invokePZ(window, minW, minH, Functions.SDL_SetWindowMinimumSize);
    }

    /// 设置窗口最大尺寸
    public static boolean SDL_SetWindowMaximumSize(long window, int maxW, int maxH) {
        return invokePZ(window, maxW, maxH, Functions.SDL_SetWindowMaximumSize);
    }

    /// 设置窗口图标（SDL_Surface* 指针）
    public static boolean SDL_SetWindowIcon(long window, long icon) {
        return callPPZ(window, icon, Functions.SDL_SetWindowIcon);
    }

    // --- 屏幕保护 ---

    public static boolean SDL_ScreenSaverEnabled() {
        return callZ(Functions.SDL_ScreenSaverEnabled);
    }

    public static boolean SDL_EnableScreenSaver() {
        return callZ(Functions.SDL_EnableScreenSaver);
    }

    public static boolean SDL_DisableScreenSaver() {
        return callZ(Functions.SDL_DisableScreenSaver);
    }

    // --- GL 库加载 ---

    public static boolean SDL_GL_LoadLibrary(ByteBuffer path) {
        return callPZ(memAddress(path), Functions.SDL_GL_LoadLibrary);
    }

    public static boolean SDL_GL_LoadLibrary(CharSequence path) {
        return SDL_GL_LoadLibrary(toByteBuffer(path));
    }

    public static long SDL_GL_GetProcAddress(ByteBuffer proc) {
        return callPP(memAddress(proc), Functions.SDL_GL_GetProcAddress);
    }

    public static long SDL_GL_GetProcAddress(CharSequence proc) {
        return SDL_GL_GetProcAddress(toByteBuffer(proc));
    }

    public static void SDL_GL_UnloadLibrary() {
        callV(Functions.SDL_GL_UnloadLibrary);
    }

    public static boolean SDL_GL_ExtensionSupported(ByteBuffer extension) {
        return callPZ(memAddress(extension), Functions.SDL_GL_ExtensionSupported);
    }

    public static boolean SDL_GL_ExtensionSupported(CharSequence extension) {
        return SDL_GL_ExtensionSupported(toByteBuffer(extension));
    }

    // --- GL 上下文管理 ---

    public static void SDL_GL_ResetAttributes() {
        callV(Functions.SDL_GL_ResetAttributes);
    }

    public static boolean SDL_GL_SetAttribute(int attr, int value) {
        // callZ(int, int, long) — 两个 int 参数 + 函数地址，返回 boolean
        return callZ(attr, value, Functions.SDL_GL_SetAttribute);
    }

    public static boolean SDL_GL_GetAttribute(int attr, IntBuffer value) {
        return callPZ(attr, memAddress(value), Functions.SDL_GL_GetAttribute);
    }

    public static long SDL_GL_CreateContext(long window) {
        return callPP(window, Functions.SDL_GL_CreateContext);
    }

    public static boolean SDL_GL_MakeCurrent(long window, long context) {
        return callPPZ(window, context, Functions.SDL_GL_MakeCurrent);
    }

    public static long SDL_GL_GetCurrentWindow() {
        return callP(Functions.SDL_GL_GetCurrentWindow);
    }

    public static long SDL_GL_GetCurrentContext() {
        return callP(Functions.SDL_GL_GetCurrentContext);
    }

    public static boolean SDL_GL_SetSwapInterval(int interval) {
        return callZ(interval, Functions.SDL_GL_SetSwapInterval);
    }

    public static boolean SDL_GL_GetSwapInterval(IntBuffer interval) {
        return callPZ(memAddress(interval), Functions.SDL_GL_GetSwapInterval);
    }

    public static boolean SDL_GL_SwapWindow(long window) {
        return callPZ(window, Functions.SDL_GL_SwapWindow);
    }

    public static boolean SDL_GL_DestroyContext(long context) {
        // SDL3 SDL_GL_DestroyContext 返回 bool，使用 callPZ(long, long)→boolean
        return callPZ(context, Functions.SDL_GL_DestroyContext);
    }

    // --- 窗口位置辅助常量 ---

    public static int SDL_WINDOWPOS_UNDEFINED_DISPLAY(int display) {
        return SDL_WINDOWPOS_UNDEFINED_MASK | display;
    }

    public static boolean SDL_WINDOWPOS_ISUNDEFINED(int x) {
        return (x & 0xFFFF0000) == SDL_WINDOWPOS_UNDEFINED_MASK;
    }

    public static int SDL_WINDOWPOS_CENTERED_DISPLAY(int display) {
        return SDL_WINDOWPOS_CENTERED_MASK | display;
    }

    public static boolean SDL_WINDOWPOS_ISCENTERED(int x) {
        return (x & 0xFFFF0000) == SDL_WINDOWPOS_CENTERED_MASK;
    }

    private SDLVideo() {
        throw new UnsupportedOperationException();
    }
}

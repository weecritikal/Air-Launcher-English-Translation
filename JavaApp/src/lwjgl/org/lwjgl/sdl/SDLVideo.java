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
 *   - 此类仅覆盖 SDL_CreateWindow 方法，其他 SDLVideo 方法（如 SDL_DestroyWindow、
 *     SDL_GetWindowFlags 等）未在此提供。若 MC 调用这些方法，将抛出
 *     NoSuchMethodError，可根据日志补齐。
 *   - 所有常量（约 130 个）从 LWJGL 3.4.1 SDLVideo.class 完整复制，
 *     避免 MC 引用常量时出现 NoSuchFieldError。
 *   - 不使用反射（避免覆盖类自身递归调用），所有 SDL3 native 调用都在
 *     native helper 中完成。
 *
 * 反射递归问题（已修复）：
 *   早期版本使用 Class.forName("org.lwjgl.sdl.SDLVideo") 反射调用
 *   SDL_CreateWindowWithProperties，但由于本类就是 org.lwjgl.sdl.SDLVideo
 *   的覆盖类，Class.forName 返回本类自身，导致 invoke 时无限递归栈溢出。
 *   现改为通过 native helper 直接调用 SDL3 函数，完全绕开反射。
 */
package org.lwjgl.sdl;

import java.nio.ByteBuffer;

import net.kdt.pojavlaunch.uikit.UIKit;

public final class SDLVideo {

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

    /// 辅助方法：CharSequence 转 ByteBuffer
    private static ByteBuffer toByteBuffer(CharSequence cs) {
        if (cs == null) return null;
        return org.lwjgl.system.MemoryUtil.memUTF8(cs);
    }

    private SDLVideo() {
        throw new UnsupportedOperationException();
    }
}

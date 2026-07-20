#import <Foundation/Foundation.h>
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include "external/fishhook/fishhook.h"
#include <dlfcn.h>

void (*orig_abort)();
void (*orig_exit)(int code);
void* (*orig_dlopen)(const char* path, int mode);
void* (*orig_dlsym)(void* handle, const char* name);
int (*orig_open)(const char *path, int oflag, ...);

// ============================================================================
// SDL3 native hook（关键修复 MC 26.3-snapshot-4+ SDL3 启动崩溃）
// ============================================================================
// 背景：
//   MC 26.3-snapshot-4+ 从 GLFW 切换到 SDL3。MC 通过 LWJGL 的 SDL binding 或
//   自己的 JNI binding 调用 SDL3 函数。LWJGL/Library.loadNative 内部用 dlsym
//   获取 SDL3 函数指针。
//
//   SDL3 UIKit 后端默认创建新的 UIWindowScene，与启动器已有的
//   GameSurfaceView（含 CAMetalLayer）冲突，导致 SDL_CreateWindow 阻塞/崩溃。
//
//   之前的方案是用 SDLVideo.java 覆盖类拦截 SDL_CreateWindow。但日志显示
//   我们的 SDL.java/SDLVideo.java 覆盖类的 println 从未出现，说明 MC 不通过
//   LWJGL 的 SDL binding 加载 SDL3（MC 26.3 可能用自己的 JNI binding）。
//
//   因此改为在 native 层 hook dlsym，拦截 SDL_CreateWindow 请求，返回我们的
//   hook 函数。hook 函数调用 amethyst_sdl_create_window_with_scene（egl_bridge.m），
//   通过 SDL3 Properties API 传入启动器的 UIWindowScene，让 SDL3 复用启动器的
//   窗口场景。

// SDL_Window 不透明类型（避免依赖 SDL3 头文件）
struct SDL_Window;
typedef struct SDL_Window SDL_Window;

// 由 egl_bridge.m 提供：用启动器 UIWindowScene 创建 SDL3 窗口
extern SDL_Window *amethyst_sdl_create_window_with_scene(int w, int h, unsigned int flags);

// 原始 SDL_CreateWindow 函数指针（dlsym hook 捕获后保存）
static SDL_Window *(*g_orig_sdl_CreateWindow)(const char *, int, int, unsigned int) = NULL;

/// 提供给 egl_bridge.m 使用的"绕过 hook"的 dlsym
/// egl_bridge.m 在获取 SDL3 函数指针时必须调用此函数，否则会被 hooked_dlsym
/// 拦截（SDL_CreateWindow 请求会返回 hook 函数，导致无限递归）。
void *amethyst_orig_dlsym(void *handle, const char *name) {
    if (orig_dlsym) {
        return orig_dlsym(handle, name);
    }
    // fallback：如果 hook 尚未初始化（不应发生），用普通 dlsym
    return dlsym(handle, name);
}

/// hook 函数：替换 SDL_CreateWindow
/// 签名必须与 SDL3 的 SDL_CreateWindow 完全一致：
///   SDL_Window *SDL_CreateWindow(const char *title, int w, int h, Uint32 flags)
static SDL_Window *amethyst_hooked_SDL_CreateWindow(const char *title, int w, int h, unsigned int flags) {
    NSLog(@"[SDL3 Hook] SDL_CreateWindow intercepted: title=%s w=%d h=%d flags=0x%x",
          title ? title : "(null)", w, h, flags);
    // 调用我们的桥接函数（会用 Properties API 传入 UIWindowScene）
    SDL_Window *window = amethyst_sdl_create_window_with_scene(w, h, flags);
    NSLog(@"[SDL3 Hook] amethyst_sdl_create_window_with_scene returned: %p", window);
    return window;
}

void handle_fatal_exit(int code) {
    if (NSThread.isMainThread) {
        return;
    }

    [PLLogOutputView handleExitCode:code];

    if (fatalExitGroup != nil) {
        // Likely other threads are crashing, put them to sleep
        sleep(INT_MAX);
    }
    fatalExitGroup = dispatch_group_create();
    dispatch_group_enter(fatalExitGroup);
    dispatch_group_wait(fatalExitGroup, DISPATCH_TIME_FOREVER);
}

void hooked_abort() {
    NSLog(@"abort() called");
    handle_fatal_exit(SIGABRT);
    orig_abort();
}

void hooked___assert_rtn(const char* func, const char* file, int line, const char* failedexpr)
{
    if (func == NULL) {
        fprintf(stderr, "Assertion failed: (%s), file %s, line %d.\n", failedexpr, file, line);
    } else {
        fprintf(stderr, "Assertion failed: (%s), function %s, file %s, line %d.\n", failedexpr, func, file, line);
    }
    hooked_abort();
}

void hooked_exit(int code) {
    NSLog(@"exit(%d) called", code);
    if (code == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication performSelector:@selector(suspend)];
        });
        usleep(100*1000);
        orig_exit(0);
        return;
    }
    handle_fatal_exit(code);

    orig_exit(code);
}

void* hooked_dlopen(const char* path, int mode) {
    const char *home = getenv("HOME");
    // Only proceed to check if dylib is in the home dir
    char fullpath[PATH_MAX];
    if (!path || !realpath(path, fullpath) || !strstr(fullpath, home)) {
        return orig_dlopen(path, mode);
    }

    PLPatchMachOPlatformForFile(path);
    return orig_dlopen(path, mode);
}

/// dlsym hook：拦截 SDL3 关键函数请求，返回我们的 hook 函数
///
/// 拦截的函数：
///   - SDL_CreateWindow → 返回 amethyst_hooked_SDL_CreateWindow
///     （让 SDL3 UIKit 后端复用启动器的 UIWindowScene）
///
/// 其他函数（包括其他 SDL_ 函数）正常返回 orig_dlsym 的结果，不记录日志，
/// 避免日志爆炸。只有 SDL_CreateWindow 被拦截时记录。
void* hooked_dlsym(void* handle, const char* name) {
    if (name != NULL && strcmp(name, "SDL_CreateWindow") == 0) {
        NSLog(@"[SDL3 Hook] dlsym intercepted: SDL_CreateWindow -> returning hook");
        // 首次拦截时，用 orig_dlsym 获取原始函数指针并保存
        // （amethyst_sdl_create_window_with_scene 内部会通过 amethyst_orig_dlsym
        //  重新获取 SDL3 函数指针，这里保存只是为了诊断/备份用途）
        if (!g_orig_sdl_CreateWindow && orig_dlsym) {
            g_orig_sdl_CreateWindow = (SDL_Window *(*)(const char *, int, int, unsigned int))
                orig_dlsym(handle, name);
            NSLog(@"[SDL3 Hook] Original SDL_CreateWindow saved: %p", (void *)g_orig_sdl_CreateWindow);
        }
        return (void *)amethyst_hooked_SDL_CreateWindow;
    }
    return orig_dlsym(handle, name);
}

int hooked_open(const char *path, int oflag, ...) {
    va_list args;
    va_start(args, oflag);
    mode_t mode = va_arg(args, int);
    va_end(args);
    if (path && !strcmp(path, "/etc/resolv.conf")) {
        return orig_open([NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")].UTF8String, oflag, mode);
    }

    return orig_open(path, oflag, mode);
}

void init_hookFunctions() {
    struct rebinding rebindings[] = (struct rebinding[]){
        {"abort", hooked_abort, (void *)&orig_abort},
        {"__assert_rtn", hooked___assert_rtn, NULL},
        {"exit", hooked_exit, (void *)&orig_exit},
        {"dlopen", hooked_dlopen, (void *)&orig_dlopen},
        {"dlsym", hooked_dlsym, (void *)&orig_dlsym},
        {"open", hooked_open, (void *)&orig_open}
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
    NSLog(@"[main_hook] SDL3 dlsym hook registered (amethyst_hooked_SDL_CreateWindow=%p)", (void *)amethyst_hooked_SDL_CreateWindow);
}

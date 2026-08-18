#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/osmesa_internal.h"
#include "utils.h"

// Default GL path; pojavInit() will set it again
int clientAPI = GLFW_OPENGL_API;

// FPS counter (modeled on the atomic_uint implementation in FCL egl_bridge.c)
// It is incremented in pojavSwapBuffers() and reset when SurfaceViewController reads it
static atomic_uint _pojavFpsCounter = 0;

// Phase 13: first-frame-rendered detection flag (modeled on FCL's game_ready callback)
// It is set to YES and a notification is posted on the first call to pojavSwapBuffers(), which SurfaceViewController uses to remove the launch overlay
static BOOL s_firstFrameRendered = NO;

unsigned int pojavGetAndResetFps() {
    return atomic_exchange(&_pojavFpsCounter, 0);
}

/// Increment the FPS counter explicitly (for use in Vulkan mode)
///
/// The Vulkan renderer does not go through EGL's pojavSwapBuffers path but presents directly through
/// MoltenVK's vkQueuePresentKHR. As a result the FPS counting logic in pojavSwapBuffers
/// never runs. In Vulkan mode SurfaceViewController uses CADisplayLink as a frame rate
/// detection fallback and increments the counter through this function every frame.
void pojavIncrementFpsCounter() {
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // First-frame-rendered detection (matching the logic in pojavSwapBuffers)
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First frame rendered (Vulkan displayLink path), game is ready");
        });
    }
}

/// Determine at runtime whether MC's real rendering path is Vulkan.
///
/// This fixes the root cause of the incorrect FPS display:
/// SurfaceViewController used to infer statically from the graphicsApi string at viewDidLoad time
/// whether to enable the CADisplayLink fallback that increments the FPS counter. But:
///   - with graphicsApi=default the decision is made inside MC and cannot be predicted (so the fallback was enabled to be safe)
///   - yet if MC actually chose the GL path, pojavSwapBuffers counts too, causing double counting
///   - conversely, if graphicsApi=prefer_vulkan but MC failed to start and fell back to GL, the fallback would increment incorrectly
///
/// The clientAPI runtime signal (written when MC calls glfwWindowHint(GLFW_CLIENT_API, ...))
/// makes it possible to determine exactly which rendering path MC is currently taking:
///   - GLFW_NO_API (0) → the Vulkan path; pojavSwapBuffers is not called, so the fallback is needed
///   - any other value (GLFW_OPENGL_API etc.) → the GL path; pojavSwapBuffers counts, so the fallback is disabled
///
/// PLDisplayLinkTarget.displayLinkTick: queries this function dynamically every frame, keeping the fallback state
/// consistent with MC's real rendering path and avoiding double or missed counting.
bool pojavIsActualVulkanPath() {
    // GLFW mode: clientAPI is written by pojavSetWindowHint(GLFW_CLIENT_API, ...),
    // and pojavInit() initializes it to GLFW_OPENGL_API. MC calls glfwWindowHint(GLFW_NO_API)
    // to switch to the Vulkan path.
    if (clientAPI == GLFW_NO_API) return true;

    return false;
}

void JNI_LWJGL_changeRenderer(const char* value_c) {
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    jclass clazz = (*env)->FindClass(env, "java/lang/System");
    jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

int pojavInitOpenGL() {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    BOOL isAuto = [renderer isEqualToString:@"auto"];
    if (isAuto || [renderer isEqualToString:@ RENDERER_NAME_GL4ES]) {
        // At this point, if renderer is still auto (unspecified major version), pick gl4es
        renderer = @ RENDERER_NAME_GL4ES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
        renderer = @ RENDERER_NAME_MOBILEGLUES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE]) {
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
        // LTW (Large Thin Wrapper) - an OpenGL Core 3.3 → OpenGL ES 3 translation layer
        // Ported from the official MojoLauncher/LTW repository, with full support for Sodium + Iris shaders.
        //
        // Key point: LTW's constructor (proc.c) needs to find EGL function symbols such as eglGetProcAddress
        // via dlsym. LTW itself only exports the three wrappers eglCreateContext / eglDestroyContext /
        // eglMakeCurrent, and forwards every other EGL function straight to the host EGL (ANGLE).
        // So ANGLE must be dlopen'ed first (RTLD_GLOBAL) so that ANGLE's EGL symbols enter the global symbol table
        // before LTW's constructor can initialize successfully.
        //
        // In LTW mode, dlsym_EGL() in gl_bridge.m dlsyms those three wrapper functions straight from libltw.dylib
        // and still resolves the remaining EGL functions from ANGLE.
        NSLog(@"[egl_bridge] LTW renderer: preloading ANGLE as host EGL before LTW init");
        dlopen("@rpath/" RENDERER_NAME_MTL_ANGLE, RTLD_GLOBAL);
        set_gl_bridge_tbl();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        setenv("GALLIUM_DRIVER","zink",1);
        set_osm_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        // Key fix (MoltenVK + OpenGL black screen + graphics API switching having no effect):
        //
        // Previously the Vulkan renderer called set_vk_bridge_tbl() one-way, and once that was set every GL call went through
        // the vk_bridge stubs (vk_init_context returns a dummy, vk_make_current is empty).
        // When MC 26.2+ chose prefer_opengl it still took the GL path (clientAPI != GLFW_NO_API),
        // but the bridge was already the vk stub → no real GL context → black screen.
        //
        // Fix strategy (modeled on the renderer + graphicsApi interplay in FCL/HMCL):
        //   1. Always initialize the GL bridge (set_gl_bridge_tbl) so the GL path has a real context
        //   2. Preload libMoltenVK.dylib at the same time (needed by the Vulkan path)
        //   3. pojavCreateContext decides its return value dynamically from clientAPI:
        //      - GLFW_NO_API (Vulkan path) → return a CAMetalLayer and let MC/LWJGL manage Vulkan themselves
        //      - otherwise (GL path) → call br_init_context to create a real EGL/GL context
        //
        // This works whether MC picks the OpenGL or the Vulkan path:
        //   - prefer_vulkan: MC takes the Vulkan path, glfwWindowHint(GLFW_NO_API) → CAMetalLayer
        //   - prefer_opengl: MC takes the GL path, glfwWindowHint(GLFW_OPENGL_API) → EGL context
        //   - default: MC decides internally, and both paths are handled
        //
        // Note: JavaLauncher.m already sets org.lwjgl.opengl.libname=libmobileglues.dylib in Vulkan mode,
        // so the GL library LWJGL loads is MobileGlues (a GL→Vulkan translation layer), which can route GL calls through the Vulkan backend.
        // This is how what users describe as "rendering the game with OpenGL plus MoltenVK to reach 120 FPS" actually works:
        // MC takes the GL path → EGL context (ANGLE Metal) → MobileGlues translation → Vulkan → MoltenVK → Metal
        // MobileGlues's Vulkan backend uses the IMMEDIATE present mode, which can exceed the screen refresh rate.
        NSLog(@"[egl_bridge] Vulkan renderer: initializing GL bridge for OpenGL path fallback (graphicsApi linkage)");
        set_gl_bridge_tbl();
        // Preload libMoltenVK.dylib (needed by the Vulkan path, harmless for the GL path)
        dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
        // In Vulkan mode the LWJGL OpenGL library is MobileGlues (set by JavaLauncher.m)
        // JNI_LWJGL_changeRenderer(RENDERER_NAME_MTL_ANGLE) is no longer called,
        // because JavaLauncher.m already set it via -Dorg.lwjgl.opengl.libname=libmobileglues.dylib
        JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
        // Skip the shared JNI_LWJGL_changeRenderer and dlopen below (already handled)
        return !br_init();
    }
    if (strcmp(renderer.UTF8String, RENDERER_NAME_VULKAN) != 0) {
        JNI_LWJGL_changeRenderer(renderer.UTF8String);
    }
    // Preload renderer library
    dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, RTLD_GLOBAL);

    return !br_init();
    //return 0;
}

void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (strcmp(getenv("AMETHYST_RENDERER"), "auto")==0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
        switch (value) {
            case 1:
            case 2:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_GL4ES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ES);
                break;
            // case 4: use Zink?
            default:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_MOBILEGLUES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
                break;
        }
    }
}

void pojavSwapBuffers() {
    // FPS counting (modeled on FCL/ZL2, which count at the native swap buffer entry point to reflect the real rendering frame rate)
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // Phase 13: first-frame-rendered detection (modeled on FCL's game_ready callback)
    // The first call to pojavSwapBuffers means the game has rendered its first frame, so post the notification to remove the launch overlay
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First frame rendered, game is ready");
        });
    }

    if (!br_swap_buffers) return;
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    if (!br_make_current) return;
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }

    const char *renderer = getenv("AMETHYST_RENDERER");
    const char *graphicsApi = getenv("AMETHYST_GRAPHICS_API");
    NSLog(@"[egl_bridge] pojavCreateContext: clientAPI=%d (GLFW_NO_API=%d), renderer=%s, graphicsApi=%s",
          clientAPI, GLFW_NO_API, renderer ?: "<unset>", graphicsApi ?: "<unset>");

    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        // MC 26.2+ with graphicsApi=prefer_vulkan or default (the Vulkan path) ends up here
        // Return a CAMetalLayer as the Vulkan surface; MC/LWJGL manage Vulkan themselves through libMoltenVK.dylib
        NSLog(@"[egl_bridge] Vulkan path: returning CAMetalLayer as Vulkan surface");
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    // GL path (clientAPI == GLFW_OPENGL_API or GLFW_OPENGL_ES_API)
    // MC 26.2+ with graphicsApi=prefer_opengl or default (the OpenGL path) ends up here
    // Call br_init_context to create a real EGL/GL context
    // Even with renderer=libMoltenVK.dylib, pojavInitOpenGL has already set the GL bridge (set_gl_bridge_tbl),
    // so this calls gl_init_context to create an ANGLE Metal EGL context
    NSLog(@"[egl_bridge] OpenGL path: creating EGL/GL context via br_init_context");
    return br_init_context(contextSrc);
}

void pojavSwapInterval(int interval) {
    // Vulkan mode diagnostics: even when br_swap_interval is NULL (Vulkan does not use the EGL swap interval),
    // the call is logged to help diagnose frame rate unlocking problems
    if (!br_swap_interval) {
        const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
        NSLog(@"[egl_bridge] pojavSwapInterval(%d) called but br_swap_interval is NULL "
              @"(likely Vulkan mode). POJAV_DISABLE_VSYNC=%s. "
              @"Vulkan present mode is controlled by vkCreateSwapchainKHR, not eglSwapInterval.",
              interval, vsyncEnv ?: "<unset>");
        return;
    }
    // Unlock the frame rate (disable vertical sync): when the launcher preference video.disable_game_vsync is on
    // (POJAV_DISABLE_VSYNC=1, set by JavaLauncher.m), force swap interval=0,
    // overriding the game's glfwSwapInterval(1) vertical sync request.
    //
    // This is where VSync actually takes effect for GL-family renderers (gl4es/ANGLE/MobileGlues)
    // （gl_bridge.m gl_swap_interval → eglSwapInterval）。
    //
    // How the ANGLE Metal backend handles eglSwapInterval:
    // - interval=0: eglSwapBuffers does not wait for vblank, so the render thread can immediately start the next frame.
    //   Core Animation still composites at the screen refresh rate (60/120Hz), but the render thread is not blocked
    //   and can keep its throughput high. Surplus frames are dropped by Core Animation, but the FPS counter reflects the rendering frame rate.
    // - interval=1: eglSwapBuffers waits for vblank and the render thread is locked to the screen refresh rate.
    //
    // This backs up PojavLauncher.java writing enableVsync=false: even if the game requests
    // VSync again at runtime (some mods/versions reset it), the native layer intercepts it.
    //
    // Difference from the Vulkan renderer:
    // - GL-family renderers (including zink): VSync is controlled through eglSwapInterval (which takes effect here)
    //   When zink creates the swapchain it picks the present mode from eglSwapInterval:
    //   interval=0 → IMMEDIATE (no vsync wait), interval=1 → FIFO (wait for vsync)
    // - The Vulkan renderer: VSync is controlled by the presentMode of vkCreateSwapchainKHR
    //   (chosen by LWJGL from glfwSwapInterval, with device capabilities detected automatically by MoltenVK)

    const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
    const char* renderer = getenv("AMETHYST_RENDERER");

    if (vsyncEnv && strcmp(vsyncEnv, "1") == 0) {
        if (interval != 0) {
            // Key fix (frame rate unlocking not working): log every VSync interception
            // Some mods (such as OptiFine and Sodium) or MC versions repeatedly call glfwSwapInterval(1) at runtime
            // to re-enable VSync. Logging every interception helps diagnose the "frame rate got locked again" problem.
            // Previously only the first few were logged, so a mod re-enabling it during play went unnoticed.
            NSLog(@"[egl_bridge] pojavSwapInterval: intercepted VSync request interval=%d -> 0 (POJAV_DISABLE_VSYNC=1, renderer=%s)", interval, renderer ?: "<unset>");
        }
        interval = 0;
    } else {
        // Only log the first few calls, to help with diagnosis
        static int s_logCount = 0;
        if (s_logCount < 3) {
            s_logCount++;
            NSLog(@"[egl_bridge] pojavSwapInterval(%d) called (POJAV_DISABLE_VSYNC=%s, renderer=%s, count=%d)",
                  interval, vsyncEnv ?: "<unset>", renderer ?: "<unset>", s_logCount);
        }
    }

    br_swap_interval(interval);
}


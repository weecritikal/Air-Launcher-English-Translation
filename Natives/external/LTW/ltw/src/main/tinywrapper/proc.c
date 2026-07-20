/**
 * Created by: artDev
 * Copyright (c) 2025 artDev, SerpentSpirale, CADIndie.
 * For use under LGPL-3.0
 *
 * iOS port: replaced Android-specific EGL loading with RTLD_DEFAULT lookup
 * to work with ANGLE EGL framework loaded by the bridge.
 */
#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "proc.h"
#include "egl.h"
#include "libraryinternal.h"
#define GL_GLEXT_PROTOTYPES
#include "GL/gl.h"
#include "GL/glext.h"

INTERNAL eglMustCastToProperFunctionPointerType (*host_eglGetProcAddress)(const char *procname);
INTERNAL es3_functions_t es3_functions;

static void error_sysegl() {
    fprintf(stderr, "LTWInit: Failed to load system EGL: %s\n", dlerror());
    abort();
}

static void error_init(const char* functionName) {
    fprintf(stderr, "LTWInit: Failed to load function \"%s\"\n", functionName);
    abort();
}

// ============================================================================
// iOS 专用：从 OpenGLES.framework 加载 GL 函数
// ============================================================================
// 背景：iOS SDL3 UIKit 后端用 EAGL（EAGLContext）创建 GL context，完全绕过
// LTW 的 EGL wrapper（eglCreateContext/eglMakeCurrent）。LTW 的 GL wrapper
// 内部调用 es3_functions.xxx，这些函数指针必须指向与 EAGLContext 配合的
// 实现，即 OpenGLES.framework 的原生 ES3 实现。
//
// 非 iOS 平台（Android/Linux）仍从 ANGLE EGL 加载（通过 eglGetProcAddress）。
static void *ios_gles_handle = NULL;

static eglMustCastToProperFunctionPointerType ios_gl_get_proc_address(const char *procname) {
    if (!ios_gles_handle) {
        ios_gles_handle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                                 RTLD_LAZY | RTLD_GLOBAL);
        if (!ios_gles_handle) {
            fprintf(stderr, "LTWInit: Failed to load OpenGLES.framework: %s\n", dlerror());
            return NULL;
        }
    }
    return (eglMustCastToProperFunctionPointerType)dlsym(ios_gles_handle, procname);
}

static void init_es3_proc() {
#define GLESFUNC(name, type) es3_functions.name = (type)host_eglGetProcAddress(#name); if(es3_functions.name == NULL) error_init(#name);
#include "es3_functions.h"
#undef GLESFUNC
#define GLESFUNC(name, type) es3_functions.name = (type)host_eglGetProcAddress(#name);
#include "es3_extended.h"
#undef GLESFUNC
}

__attribute__((constructor, used)) void proc_init(){
    // ============================================================================
    // iOS 路径：从 OpenGLES.framework 加载 GL 函数
    // ============================================================================
    // iOS SDL3 UIKit 后端用 EAGL（EAGLContext）创建 GL context，不走 EGL。
    // LTW 的 GL wrapper 内部调用 es3_functions.xxx，必须指向 OpenGLES.framework
    // 的原生 ES3 实现，才能与 EAGLContext 配合工作。
    //
    // 注意：iOS 上 host_eglCreateContext/Destroy/MakeCurrent 会为 NULL
    // （OpenGLES.framework 不导出 EGL 函数），但 iOS 上 LTW 的 EGL wrapper
    // 不会被调用，current_context 通过 ltw_ensure_default_context() 自动初始化。
    void* glesHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                              RTLD_LAZY | RTLD_GLOBAL);
    if (glesHandle != NULL) {
        host_eglGetProcAddress = ios_gl_get_proc_address;
        printf("LTWInit: iOS path active, loading GL functions from OpenGLES.framework\n");
    } else {
        // ============================================================================
        // 非 iOS 路径（Android/Linux）：从 ANGLE EGL 加载（原逻辑）
        // ============================================================================
        void* angleHandle = dlopen("@rpath/libtinygl4angle.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (angleHandle != NULL) {
            host_eglGetProcAddress = dlsym(angleHandle, "eglGetProcAddress");
        }
        if (host_eglGetProcAddress == NULL) {
            host_eglGetProcAddress = dlsym(RTLD_DEFAULT, "eglGetProcAddress");
        }
        if (host_eglGetProcAddress == NULL) {
            const char* systemEglPath = "libEGL.so";
            const char* eglPath = getenv("LIBGL_EGL") != NULL ? getenv("LIBGL_EGL") : systemEglPath;
            int flags = RTLD_LAZY | RTLD_LOCAL;
            void* eglHandle = dlopen(eglPath, flags);
            if(eglHandle == NULL){
                printf("LTWInit: failed loading custom libEGL, using default\n");
                eglHandle = dlopen(systemEglPath, flags);
                if(eglHandle == NULL)
                    error_sysegl();
            }
            host_eglGetProcAddress = dlsym(eglHandle, "eglGetProcAddress");
        }
    }
    if(host_eglGetProcAddress == NULL) error_sysegl();
    init_egl();
    init_es3_proc();
}

// This is exported for it to be automatically picked up by LWJGL's symbol resolver.
__attribute__((used)) eglMustCastToProperFunctionPointerType glXGetProcAddress(const char *procname) {
    return eglGetProcAddress(procname);
}

extern void* resolve_stub(const char* procname);

eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *procname) {
    // EGL functions that we implement.
    // All of the other platform EGL functions will be redirected into Android's default EGL implementation.
    if(!strncmp(procname, "egl", 3)) {
        if(!strcmp("eglCreateContext", procname)) return (eglMustCastToProperFunctionPointerType) eglCreateContext;
        if(!strcmp("eglDestroyContext", procname)) return (eglMustCastToProperFunctionPointerType) eglDestroyContext;
        if(!strcmp("eglMakeCurrent", procname)) return (eglMustCastToProperFunctionPointerType) eglMakeCurrent;
    }
    // If the function doesn't start with "gl", don't even bother, pass through immediately.
    if(strncmp(procname, "gl", 2) != 0) goto fallback;
#define GLESOVERRIDE(name)                                        \
    if(!strcmp(procname, #name)) {                                \
        printf("LTW: Overridden %s\n", #name);                        \
        return (eglMustCastToProperFunctionPointerType) name;     \
    }
#include "es3_overrides.h"
#undef GLESOVERRIDE
    eglMustCastToProperFunctionPointerType function;
fallback:
    function = host_eglGetProcAddress(procname);
    if(function == NULL) {
        function = resolve_stub(procname);
    }
    return function;
}

/**
 * Created by: artDev
 * Copyright (c) 2025 artDev, SerpentSpirale, CADIndie.
 * For use under LGPL-3.0
 *
 * iOS 移植（Angel Aura Amethyst）：
 *   - 移除 android/log.h 依赖，用 printf 替代 __android_log_print
 *   - proc_init 从 libtinygl4angle.dylib 加载 eglGetProcAddress
 *     （libtinygl4angle.dylib 链接到 libEGL.framework，dlsym 会搜索其依赖库）
 *   - 保留 LIBGL_EGL 环境变量作为 fallback，便于调试
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
    printf("LTWInit: Failed to load system EGL: %s\n", dlerror());
    abort();
}

static void error_init(const char* functionName) {
    printf("LTWInit: Failed to load function \"%s\"\n", functionName);
    abort();
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
    /* iOS：libtinygl4angle.dylib 是 ANGLE wrapper（链接到 libEGL.framework +
       libGLESv2.framework），提供 eglGetProcAddress。LTW 通过它加载所有 ES3 函数。
       LIBGL_EGL 环境变量作为可选覆盖（便于调试切换 host EGL）。 */
    const char* defaultEglPath = "@rpath/libtinygl4angle.dylib";
    const char* eglPath = getenv("LIBGL_EGL") != NULL ? getenv("LIBGL_EGL") : defaultEglPath;
    int flags = RTLD_LAZY | RTLD_LOCAL;
    void* eglHandle = dlopen(eglPath, flags);
    if(eglHandle == NULL){
        printf("LTWInit: failed loading custom EGL (%s), trying default (%s): %s\n",
               eglPath, defaultEglPath, dlerror());
        eglHandle = dlopen(defaultEglPath, flags);
        if(eglHandle == NULL)
            error_sysegl();
    }
    /* libtinygl4angle.dylib 自身不导出 eglGetProcAddress（只提供 GL wrapper），
       但它链接到 libEGL.framework，dlsym 会搜索依赖库找到 ANGLE 的 eglGetProcAddress。 */
    host_eglGetProcAddress = dlsym(eglHandle, "eglGetProcAddress");
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

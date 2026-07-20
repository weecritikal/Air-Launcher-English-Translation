
#include "environ/environ.h"
#include "utils.h"
#include "native_hooks.h"
#include "log.h"
#include "SDL3/SDL.h"

#include <bytehook.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdlib.h>

#define SET_DLSYM_PTR(fn) \
    fn##_t fn##_p;              \
    do { \
        dlerror(); \
        void *_p = dlsym(RTLD_NEXT, #fn); \
        const char *_e = dlerror(); \
        if (_e || !_p) { \
            LOGE("dlsym(%s) failed: %s\n", #fn, _e ? _e : "unknown error"); \
        } \
        fn##_p = (typeof(fn##_t))_p; \
    } while (0)

#define DECL_DLSYM(fn) typedef typeof(&fn) fn##_t;

#define TRY_ATTACH_ENV(fn) \
    JNIEnv *dvm_env; \
    dvm_env = get_attached_env(pojav_environ->dalvikJavaVMPtr); \
    if (dvm_env == ((void *) 0)) {printf("%s notify to launcher-side integration failed!\n", #fn);}


DECL_DLSYM(SDL_InitSubSystem)
DECL_DLSYM(SDL_SetHint);
DECL_DLSYM(SDL_SetTextInputArea);

static bool notifyLauncher(JNIEnv *dvm_env, int type, int actions[], int len){
    jintArray actionArray = (*dvm_env)->NewIntArray(dvm_env, len);
    (*dvm_env)->SetIntArrayRegion(dvm_env, actionArray, 0, len, actions);
    return (*dvm_env)->CallStaticBooleanMethod(dvm_env, pojav_environ->bridgeClazz,
            pojav_environ->method_notifyLauncher, type, actionArray);
}

#define NOTIF_TYPE_SDL 0
#define ACTION_INIT_LAUNCHER_INTEGRATION 0
#define ACTION_SEND_TEXTBOX_RECT 1



static bool custom_SDL_InitSubSystem_Func(SDL_InitFlags flags) {
    // Call notifyLauncher on SDL_InitSubSystem, this sets up all the JNI stuff needed by SDL.
    TRY_ATTACH_ENV(SDL_InitSubSystem);
    // Just in case of bozo
    jint safeFlags;
    if (flags > INT32_MAX) {
        safeFlags = -1;
    } else safeFlags = (jint)flags;

    notifyLauncher(dvm_env, NOTIF_TYPE_SDL, (int[]){ACTION_INIT_LAUNCHER_INTEGRATION, safeFlags}, 2);

    // This is the normal for the launcher, the default in SDL is false.
    SET_DLSYM_PTR(SDL_SetHint);
    if (SDL_SetHint_p) SDL_SetHint_p("SDL_RETURN_KEY_HIDES_IME", "true");

    // Call original func after doing all the needed setup
    bool r = BYTEHOOK_CALL_PREV(custom_SDL_InitSubSystem_Func, SDL_InitSubSystem_t, flags);
    BYTEHOOK_POP_STACK();
    return r;
}

//// This doesn't work because lwjgl doesn't use plt/got to access the bindings, fml
//static bool custom_SDL_SetTextInputArea_Func(SDL_Window *window, const SDL_Rect *rect, int cursor) {
//    TRY_ATTACH_ENV(SDL_GetTextInputArea);
//    notifyLauncher(dvm_env, NOTIF_TYPE_SDL, (int[]) {
//        ACTION_SEND_TEXTBOX_RECT,
//        rect->x, rect->y, rect->x + rect->w, rect->y + rect->h, cursor
//    }, 6);
//    int r = BYTEHOOK_CALL_PREV(custom_SDL_SetTextInputArea_Func, SDL_SetTextInputArea_t, window, rect, cursor);
//    BYTEHOOK_POP_STACK();
//    return r;
//}


void create_sdl_hooks(bytehook_hook_all_t bytehook_hook_all_p) {
    bytehook_stub_t stub_SDL_InitSubSystem = bytehook_hook_all_p("libSDL3.so", "SDL_InitSubSystem", &custom_SDL_InitSubSystem_Func, NULL, NULL);
    LOGI("Successfully initialized SDL hooks, stubs: %p, %p\n", stub_SDL_InitSubSystem);
}
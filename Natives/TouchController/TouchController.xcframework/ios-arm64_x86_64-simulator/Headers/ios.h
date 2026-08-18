#ifndef TOUCHCONTROLLER_IOS_H
#define TOUCHCONTROLLER_IOS_H

#include <jni.h>
#include <pthread.h>
#include <stdint.h>

#include "touchcontroller/proxy/server/util/ringbuffer/ring_buffer.h"

#ifdef __cplusplus
extern "C" {
#endif

// Internal structures of the iOS transport
// A same-process two-ended in-memory queue: on iOS the launcher and the mod live in the same process, so no cross-process socket communication is needed.
// Data flow directions:
//   - Mod → launcher: the mod calls Transport.send() (JNI) to enqueue into to_launcher_queue;
//                  the launcher calls touchcontroller_ios_receive() (the C API) to dequeue.
//   - Launcher → mod: the launcher calls touchcontroller_ios_send() (the C API) to enqueue into to_mod_queue;
//                  the mod calls Transport.receive() (JNI) to dequeue.
typedef struct ios_transport {
    ring_buffer_t* to_launcher_queue;   // Mod → launcher (the mod enqueues with send, the launcher dequeues with receive)
    ring_buffer_t* to_mod_queue;        // Launcher → mod (the launcher enqueues with send, the mod dequeues with receive)
    pthread_mutex_t to_launcher_mutex;  // The mutex protecting to_launcher_queue
    pthread_mutex_t to_mod_mutex;       // The mutex protecting to_mod_queue
    // Insufficient buffer handling: when the launcher's receive finds a message whose size > buffer_length,
    // it is stashed in pending_message and used first by the next receive.
    // This is only used in the to_launcher_queue direction (the launcher's receive).
    // Return value convention: >0=bytes received, 0=no message, -1=error, -2=buffer too small
    struct message* pending_message;
} ios_transport_t;

// ===== JNI API (called by the mod through the JVM's JNI) =====
// init: a reserved extension point for NeoForge registerNatives, currently a no-op
JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_init(JNIEnv* env,
                                                                                               jclass clazz);

// new: create a transport and return its handle (0 means failure)
JNIEXPORT jlong JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_new(JNIEnv* env,
                                                                                               jclass clazz,
                                                                                               jstring path);

// receive: take one message off to_mod_queue into buffer and return the byte count (0=no message, negative=error)
JNIEXPORT jint JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_receive(JNIEnv* env,
                                                                                                  jclass clazz,
                                                                                                  jlong handle,
                                                                                                  jbyteArray buffer);

// send: enqueue buffer[off, off+len) as a message on to_launcher_queue
JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_send(JNIEnv* env,
                                                                                               jclass clazz,
                                                                                               jlong handle,
                                                                                               jbyteArray buffer,
                                                                                               jint off,
                                                                                               jint len);

// destroy: destroy the transport and release every resource
JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_destroy(JNIEnv* env,
                                                                                                  jclass clazz,
                                                                                                  jlong handle);

// ===== C API (called by the launcher directly through dlsym, with no JNIEnv) =====
// It shares the same internal implementation as the JNI API, and the signatures match the function pointer types in TouchControllerBridge.m
void touchcontroller_ios_init(void);
long long touchcontroller_ios_new(const char* path);
int touchcontroller_ios_receive(long long handle, void* buffer, int buffer_length);
void touchcontroller_ios_send(long long handle, const void* buffer, int offset, int length);
void touchcontroller_ios_destroy(long long handle);

#ifdef __cplusplus
}
#endif

#endif

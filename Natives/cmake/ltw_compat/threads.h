/**
 * iOS compatibility layer: provides C11 <threads.h> support for LTW
 *
 * The iOS SDK does not ship a <threads.h> system header, but LTW's proc.h and glsl_optimizer's
 * u_queue.c / u_thread.h and friends need the C11 threads API. This header provides those APIs by including
 * the POSIX emulation library c11/threads.h that ships with glsl_optimizer.
 *
 * Adding this directory to the include path makes `#include <threads.h>` resolve to this file.
 */
#ifndef LTW_COMPAT_THREADS_H
#define LTW_COMPAT_THREADS_H

/* The C11 thread_local keyword (iOS clang supports _Thread_local natively) */
#define thread_local _Thread_local

/* Use the C11 threads POSIX emulation library that ships with glsl_optimizer */
#include "c11/threads.h"

#endif /* LTW_COMPAT_THREADS_H */

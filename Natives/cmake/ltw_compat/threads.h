#ifndef LTW_COMPAT_THREADS_H
#define LTW_COMPAT_THREADS_H

/*
 * iOS 兼容层：iOS SDK 不提供 <threads.h>，但 LTW 的 proc.h 和
 * glsl_optimizer 的 u_queue.c / u_thread.h 等需要 C11 threads API
 *（mtx_t, cnd_t, thrd_t, once_flag, call_once, mtx_init 等）。
 *
 * 解决方案：把 <threads.h> 重定向到 glsl_optimizer/include/c11/threads.h
 *（完整的 C11 threads POSIX 模拟库），并定义 thread_local 关键字。
 *
 * 注意：必须保持 include 路径优先级——cmake/ltw_compat 必须在
 * glsl_optimizer/include 之前，否则 <threads.h> 会匹配到
 * glsl_optimizer/include/c11/threads.h 而非本文件（虽然功能等价，
 * 但本文件还额外提供 thread_local 定义）。
 */

/* AppleClang 支持 _Thread_local 内建关键字 */
#ifndef thread_local
#define thread_local _Thread_local
#endif

/* 包含完整的 C11 threads POSIX 模拟库（提供 mtx_t/cnd_t/thrd_t/once_flag 等）*/
#include "c11/threads.h"

#endif /* LTW_COMPAT_THREADS_H */

//
//  ios_transport.h
//  Angel Aura Amethyst
//
//  TouchController iOS 传输层 C API 头文件
//  供启动器通过 dlsym 直接调用（无 JNIEnv），同时声明内部结构供 ios_transport.c 共享
//
//  本头文件不声明 JNI API —— JNI 函数由 JVM 通过命名约定查找
//  （Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_*），
//  无需在头文件中声明。
//

#ifndef IOS_TRANSPORT_H
#define IOS_TRANSPORT_H

#include <stddef.h>
#include <pthread.h>
#include "ring_buffer.h"

#ifdef __cplusplus
extern "C" {
#endif

// 内部结构：iOS transport 句柄
// 对应 TouchController 仓库 android.c 中的 android_poller_t，
// 增加 listen_fd（双端架构）和 pipe_read_fd/pipe_write_fd（替代 eventfd）
typedef struct ios_transport {
    int socket_fd;              // 已连接的 socket（阶段 2 使用）
    int listen_fd;              // listen socket，仅服务器模式使用，accept 后关闭
    int pipe_read_fd;           // pipe 读端（替代 Linux eventfd，工作线程 poll 监听）
    int pipe_write_fd;          // pipe 写端（发送/destroy 时写入以唤醒工作线程）
    ring_buffer_t* read_buffer; // 接收消息队列（工作线程入队，receive 出队）
    ring_buffer_t* write_buffer;// 发送消息队列（send 入队，工作线程出队）
    pthread_mutex_t read_mutex; // 保护 read_buffer
    pthread_mutex_t write_mutex;// 保护 write_buffer
    pthread_t worker_thread;    // 工作线程
    volatile int running;       // 运行标志（0 表示请求退出）
    volatile int failed;        // 错误标志（POLLERR/POLLHUP 时置 1）
    int is_server;              // 是否服务器模式（connect 失败后 bind+listen）
} ios_transport_t;

// === 内部核心函数 ===
// C API 与 JNI API 共用 create/destroy；send/receive 各自实现（JNI 需调用 JNIEnv）

// 创建 transport：先 connect，失败（ECONNREFUSED/ENOENT）则 bind+listen 等待 accept
// 成功返回 transport 指针，失败返回 NULL
ios_transport_t* ios_transport_create(const char* path);

// 销毁 transport：唤醒工作线程 → join → 关闭 fd → 释放 buffer/mutex/结构
void ios_transport_destroy(ios_transport_t* transport);

// C API 内部 receive：从 read_buffer 出队一条消息，拷贝到 buffer（最多 buffer_length 字节）
// 返回实际拷贝的字节数（0 表示无消息，-1 表示 transport 已失败）
int ios_transport_receive(ios_transport_t* transport, void* buffer, int buffer_length);

// C API 内部 send：构造消息入队 write_buffer，写入 pipe 唤醒工作线程
void ios_transport_send(ios_transport_t* transport, const void* buffer, int offset, int length);

// === C API（供启动器通过 dlsym 直接调用，无 JNIEnv）===
// touchcontroller_ios_new 失败返回 -1（注意：非 0，因 0 可能被误认为有效句柄）

// 预留扩展点，当前为 no-op
void touchcontroller_ios_init(void);

// 创建 transport，返回句柄（失败返回 -1）
long long touchcontroller_ios_new(const char* path);

// 接收消息（返回拷贝字节数，0=无数据，-1=失败）
int touchcontroller_ios_receive(long long handle, void* buffer, int buffer_length);

// 发送消息（length 须在 1-255 范围内）
void touchcontroller_ios_send(long long handle, const void* buffer, int offset, int length);

// 销毁 transport
void touchcontroller_ios_destroy(long long handle);

#ifdef __cplusplus
}
#endif

#endif // IOS_TRANSPORT_H

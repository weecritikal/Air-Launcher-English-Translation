//
//  ios_transport.c
//  Angel Aura Amethyst
//
//  TouchController iOS 传输层实现
//
//  本文件实现完整的 iOS 传输层，与 TouchController 仓库 android.c 共享核心逻辑，
//  并针对 iOS 平台做了以下替换：
//    1. eventfd()                    → pipe()            （工作线程唤醒机制）
//    2. abstract namespace socket     → 文件系统路径 socket （iOS 不支持 Linux 抽象命名空间）
//    3. SOCK_CLOEXEC 标志             → fcntl(FD_CLOEXEC) （iOS 不支持 SOCK_CLOEXEC）
//
//  双端架构：ios_transport_create(path) 先 connect()，失败（ECONNREFUSED/ENOENT）
//  则执行 bind()+listen()+accept()（在工作线程中阻塞等待）。
//
//  提供两套 API（共用内部实现）：
//    - C API（touchcontroller_ios_*）：供启动器通过 dlsym 直接调用
//    - JNI API（Java_..._Transport_*）：供 Mod 通过 JVM JNI 调用
//

#include "ios_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <jni.h>

// 4K 初始队列大小（与 android.c 一致）
#define MAX_QUEUE_SIZE (4 * 1024)

// 消息结构（对应 android.c 中的 message_t）
// 传输层消息格式：[1 字节长度 N (1-255)] [N 字节 payload]
typedef struct message {
    size_t size;                // payload 字节数（1-255）
    ssize_t bytes_processed;    // 已处理字节数；-1 表示尚未写入长度字节
    uint8_t* data;              // payload 数据
} message_t;

static void free_message(message_t* msg) {
    if (msg) {
        if (msg->data) free(msg->data);
        free(msg);
    }
}

// === 工作线程：两阶段运行模型 ===
//
// 阶段 1（仅服务器模式）：poll listen_fd 的 POLLIN，连接到来时 accept，
//   关闭 listen_fd，转入阶段 2。同时 poll pipe_read_fd 以响应 destroy 唤醒。
//
// 阶段 2：poll socket_fd 的 POLLIN/POLLOUT + pipe_read_fd 的 POLLIN：
//   - POLLIN on socket → 读取消息（1 字节长度 + N 字节 payload）入 read_buffer
//   - POLLOUT on socket 或 POLLIN on pipe → 从 write_buffer 取消息写入 socket
//
// 客户端模式跳过阶段 1，直接进入阶段 2。
static void* worker_thread(void* arg) {
    ios_transport_t* transport = (ios_transport_t*)arg;

    int socket_fd = transport->socket_fd;     // 客户端模式：已连接；服务器模式：阶段 1 后更新
    int pipe_read_fd = transport->pipe_read_fd;
    int listen_fd = transport->listen_fd;     // 仅服务器模式有效

    // 消息指针声明在函数顶部并初始化为 NULL，确保 goto 跳转时不会访问未初始化值
    message_t* message_tx = NULL;   // 正在发送的消息（部分写入时暂存）
    message_t* message_rx = NULL;   // 正在接收的消息（部分读取时暂存）

    // === 阶段 1：等待连接（仅服务器模式） ===
    if (transport->is_server) {
        struct pollfd fds_phase1[2];
        fds_phase1[0].fd = listen_fd;
        fds_phase1[0].events = POLLIN;
        fds_phase1[1].fd = pipe_read_fd;
        fds_phase1[1].events = POLLIN;

        while (transport->running) {
            int ret = poll(fds_phase1, 2, -1);
            if (ret < 0) {
                if (errno == EINTR) continue;
                goto fail;
            }

            // pipe 有数据：可能是 destroy 通知（running=0）或 send 通知
            if (fds_phase1[1].revents & POLLIN) {
                uint8_t val;
                read(pipe_read_fd, &val, sizeof(val));
                // 如果 running 已为 0，直接退出（destroy 被调用）
                if (!transport->running) goto cleanup;
                // 否则只是 send 通知，连接尚未建立，消息留在 write_buffer 中等待阶段 2 处理
            }

            // listen socket 有连接到来
            if (fds_phase1[0].revents & POLLIN) {
                int new_fd = accept(listen_fd, NULL, NULL);
                if (new_fd < 0) {
                    if (errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN) continue;
                    goto fail;
                }
                // 设置非阻塞
                int flags = fcntl(new_fd, F_GETFL, 0);
                if (flags >= 0) {
                    fcntl(new_fd, F_SETFL, flags | O_NONBLOCK);
                }
                // 设置 FD_CLOEXEC（替代 SOCK_CLOEXEC）
                fcntl(new_fd, F_SETFD, FD_CLOEXEC);

                socket_fd = new_fd;
                transport->socket_fd = new_fd;
                // 关闭 listen socket，不再接受新连接
                close(listen_fd);
                transport->listen_fd = -1;
                listen_fd = -1;
                break;
            }

            if (fds_phase1[0].revents & (POLLERR | POLLHUP)) goto fail;
        }
        // destroy 被调用时退出
        if (!transport->running) goto cleanup;
    }

    // === 阶段 2：正常通信 ===
    {
        struct pollfd fds[2];
        fds[0].fd = socket_fd;
        fds[1].fd = pipe_read_fd;
        fds[1].events = POLLIN;

        while (transport->running) {
            // 当有待发送消息时，监听 socket 的 POLLOUT
            fds[0].events = POLLIN | (message_tx != NULL ? POLLOUT : 0);

            int ret = poll(fds, 2, -1);
            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (!transport->running) break;

            // socket 可读：读取消息入 read_buffer
            if (fds[0].revents & POLLIN) {
                while (1) {
                    // 分配消息结构
                    if (message_rx == NULL) {
                        message_rx = malloc(sizeof(message_t));
                        if (message_rx == NULL) goto fail;
                        message_rx->size = 0;
                        message_rx->data = NULL;
                        message_rx->bytes_processed = 0;
                    }

                    // 读取 1 字节消息长度
                    if (message_rx->size == 0) {
                        uint8_t buf;
                        ssize_t len = read(socket_fd, &buf, sizeof(buf));
                        if (len <= 0) {
                            if (len < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) break;
                            goto fail;
                        }
                        if (buf == 0) continue;  // 长度为 0 的消息忽略
                        message_rx->size = buf;
                        message_rx->data = malloc(buf);
                        if (message_rx->data == NULL) goto fail;
                        message_rx->bytes_processed = 0;
                    }

                    // 读取 payload
                    size_t remaining = message_rx->size - message_rx->bytes_processed;
                    ssize_t len = read(socket_fd, &message_rx->data[message_rx->bytes_processed], remaining);
                    if (len <= 0) {
                        if (len < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) break;
                        goto fail;
                    }
                    message_rx->bytes_processed += len;
                    remaining = message_rx->size - message_rx->bytes_processed;

                    // 消息读取完成，入队 read_buffer
                    if (remaining == 0) {
                        pthread_mutex_lock(&transport->read_mutex);
                        ring_buffer_enqueue(transport->read_buffer, message_rx);
                        pthread_mutex_unlock(&transport->read_mutex);
                        message_rx = NULL;
                    }
                }
            }

            // socket 可写 或 pipe 有通知 或 有待发送消息：写入 socket
            if ((fds[0].revents & POLLOUT) || (fds[1].revents & POLLIN) || (message_tx != NULL)) {
                // 清除 pipe 通知事件
                if (fds[1].revents & POLLIN) {
                    uint8_t val;
                    read(pipe_read_fd, &val, sizeof(val));
                }

                while (1) {
                    // 从 write_buffer 取消息
                    if (message_tx == NULL) {
                        pthread_mutex_lock(&transport->write_mutex);
                        message_tx = ring_buffer_dequeue(transport->write_buffer);
                        pthread_mutex_unlock(&transport->write_mutex);
                    }
                    if (message_tx == NULL) break;  // 队列为空

                    // 写入 1 字节消息长度（bytes_processed < 0 表示尚未写入长度）
                    if (message_tx->bytes_processed < 0) {
                        uint8_t buf = (uint8_t)message_tx->size;
                        if (write(socket_fd, &buf, sizeof(buf)) <= 0) {
                            if (errno == EWOULDBLOCK || errno == EAGAIN) break;
                            goto fail;
                        }
                        message_tx->bytes_processed = 0;
                    }

                    // 写入 payload
                    size_t remaining = message_tx->size - message_tx->bytes_processed;
                    ssize_t len = write(socket_fd, &message_tx->data[message_tx->bytes_processed], remaining);
                    if (len <= 0) {
                        if (len < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) break;
                        goto fail;
                    }
                    message_tx->bytes_processed += len;
                    remaining = message_tx->size - message_tx->bytes_processed;

                    if (remaining == 0) {
                        // 消息发送完成
                        free_message(message_tx);
                        message_tx = NULL;
                    } else {
                        // 部分写入，等待下次 POLLOUT
                        break;
                    }
                }
            }

            // socket 错误或对端关闭
            if (fds[0].revents & (POLLERR | POLLHUP)) goto fail;
        }

        goto cleanup;
    }

fail:
    transport->failed = 1;
cleanup:
    free_message(message_tx);
    free_message(message_rx);
    return NULL;
}

// === 内部核心函数 ===

// 创建 transport：先 connect，失败则 bind+listen（服务器模式）
ios_transport_t* ios_transport_create(const char* path) {
    if (path == NULL) {
        return NULL;
    }

    ios_transport_t* transport = malloc(sizeof(ios_transport_t));
    if (transport == NULL) {
        return NULL;
    }
    transport->socket_fd = -1;
    transport->listen_fd = -1;
    transport->pipe_read_fd = -1;
    transport->pipe_write_fd = -1;
    transport->running = 1;
    transport->failed = 0;
    transport->is_server = 0;
    transport->read_buffer = NULL;
    transport->write_buffer = NULL;

    int mutex_read_inited = 0;
    int mutex_write_inited = 0;

    // 创建 pipe（替代 Linux eventfd），用于唤醒工作线程
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        goto cleanup_transport;
    }
    transport->pipe_read_fd = pipefd[0];
    transport->pipe_write_fd = pipefd[1];
    // 设置 pipe 读写端为非阻塞和 FD_CLOEXEC
    fcntl(transport->pipe_read_fd, F_SETFL, fcntl(transport->pipe_read_fd, F_GETFL, 0) | O_NONBLOCK);
    fcntl(transport->pipe_write_fd, F_SETFL, fcntl(transport->pipe_write_fd, F_GETFL, 0) | O_NONBLOCK);
    fcntl(transport->pipe_read_fd, F_SETFD, FD_CLOEXEC);
    fcntl(transport->pipe_write_fd, F_SETFD, FD_CLOEXEC);

    // 检查 socket 路径长度（文件系统路径，非 Linux 抽象命名空间）
    struct sockaddr_un addr;
    size_t path_len = strlen(path);
    if (path_len > sizeof(addr.sun_path) - 1) {
        goto cleanup_all;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    // 创建 socket（不使用 SOCK_CLOEXEC，改用 fcntl）
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == -1) {
        goto cleanup_all;
    }
    fcntl(sock, F_SETFD, FD_CLOEXEC);

    // 先尝试 connect（客户端模式）
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
        // 客户端模式：connect 成功
        transport->is_server = 0;
        transport->socket_fd = sock;
        // 设置非阻塞
        int flags = fcntl(sock, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        }
    } else {
        // connect 失败：仅 ECONNREFUSED/ENOENT 时回退到服务器模式
        if (errno != ECONNREFUSED && errno != ENOENT) {
            close(sock);
            goto cleanup_all;
        }
        // 服务器模式：先 unlink 旧 socket 文件，避免 bind 失败
        unlink(path);
        if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
            close(sock);
            goto cleanup_all;
        }
        if (listen(sock, 1) == -1) {
            close(sock);
            goto cleanup_all;
        }
        // listen socket 设为非阻塞
        int flags = fcntl(sock, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        }
        transport->is_server = 1;
        transport->listen_fd = sock;
        transport->socket_fd = -1;  // accept 后才设置
    }

    // 分配 ring buffer（读写队列）
    transport->read_buffer = ring_buffer_alloc(MAX_QUEUE_SIZE);
    transport->write_buffer = ring_buffer_alloc(MAX_QUEUE_SIZE);
    if (!transport->read_buffer || !transport->write_buffer) {
        goto cleanup_all;
    }

    // 初始化 mutex
    if (pthread_mutex_init(&transport->read_mutex, NULL) != 0) {
        goto cleanup_all;
    }
    mutex_read_inited = 1;

    if (pthread_mutex_init(&transport->write_mutex, NULL) != 0) {
        goto cleanup_all;
    }
    mutex_write_inited = 1;

    // 启动工作线程
    if (pthread_create(&transport->worker_thread, NULL, worker_thread, transport) != 0) {
        goto cleanup_all;
    }

    return transport;

cleanup_all:
    if (mutex_write_inited) pthread_mutex_destroy(&transport->write_mutex);
    if (mutex_read_inited) pthread_mutex_destroy(&transport->read_mutex);
    if (transport->write_buffer) ring_buffer_free(transport->write_buffer);
    if (transport->read_buffer) ring_buffer_free(transport->read_buffer);
    if (transport->socket_fd != -1) close(transport->socket_fd);
    if (transport->listen_fd != -1) close(transport->listen_fd);
    if (transport->pipe_read_fd != -1) close(transport->pipe_read_fd);
    if (transport->pipe_write_fd != -1) close(transport->pipe_write_fd);
    // 服务器模式下残留的 socket 文件由下次创建时 unlink，这里不清理

cleanup_transport:
    free(transport);
    return NULL;
}

// 销毁 transport：唤醒工作线程 → join → 释放所有资源
void ios_transport_destroy(ios_transport_t* transport) {
    if (transport == NULL) {
        return;
    }

    // 设置 running = 0，写入 pipe 唤醒工作线程
    transport->running = 0;
    if (transport->pipe_write_fd != -1) {
        uint8_t val = 1;
        write(transport->pipe_write_fd, &val, sizeof(val));
    }

    // 等待工作线程退出
    pthread_join(transport->worker_thread, NULL);

    // 关闭 socket 和 pipe
    if (transport->socket_fd != -1) close(transport->socket_fd);
    if (transport->listen_fd != -1) close(transport->listen_fd);
    if (transport->pipe_read_fd != -1) close(transport->pipe_read_fd);
    if (transport->pipe_write_fd != -1) close(transport->pipe_write_fd);

    // 销毁 mutex
    pthread_mutex_destroy(&transport->read_mutex);
    pthread_mutex_destroy(&transport->write_mutex);

    // 清空 ring buffer 中的残留消息
    message_t* msg;
    while ((msg = ring_buffer_dequeue(transport->read_buffer))) free_message(msg);
    while ((msg = ring_buffer_dequeue(transport->write_buffer))) free_message(msg);
    if (transport->read_buffer) ring_buffer_free(transport->read_buffer);
    if (transport->write_buffer) ring_buffer_free(transport->write_buffer);

    free(transport);
}

// C API 内部 receive：从 read_buffer 出队消息，拷贝到 buffer
int ios_transport_receive(ios_transport_t* transport, void* buffer, int buffer_length) {
    if (transport == NULL) {
        return -1;
    }
    if (transport->failed) {
        return -1;
    }

    // 从 read_buffer 出队一条消息
    pthread_mutex_lock(&transport->read_mutex);
    message_t* message = ring_buffer_dequeue(transport->read_buffer);
    pthread_mutex_unlock(&transport->read_mutex);

    if (message == NULL) {
        return 0;  // 无消息
    }

    // 拷贝到调用方 buffer（最多 buffer_length 字节）
    int copy_len = (int)message->size;
    if (copy_len > buffer_length) {
        copy_len = buffer_length;
    }
    if (copy_len > 0 && buffer) {
        memcpy(buffer, message->data, copy_len);
    }

    free_message(message);
    return copy_len;
}

// C API 内部 send：构造消息入队 write_buffer，写入 pipe 唤醒工作线程
void ios_transport_send(ios_transport_t* transport, const void* buffer, int offset, int length) {
    if (transport == NULL || buffer == NULL) {
        return;
    }
    if (transport->failed) {
        return;
    }
    if (length <= 0 || length > UINT8_MAX) {
        return;
    }

    // 构造消息
    message_t* message = malloc(sizeof(message_t));
    if (message == NULL) {
        return;
    }
    message->size = length;
    message->bytes_processed = -1;  // -1 表示尚未写入长度字节
    message->data = malloc(length);
    if (message->data == NULL) {
        free(message);
        return;
    }
    memcpy(message->data, (const uint8_t*)buffer + offset, length);

    // 入队 write_buffer
    pthread_mutex_lock(&transport->write_mutex);
    int ret = ring_buffer_enqueue(transport->write_buffer, message);
    pthread_mutex_unlock(&transport->write_mutex);
    if (ret != 0) {
        free_message(message);
        return;
    }

    // 写入 pipe 唤醒工作线程
    uint8_t val = 1;
    write(transport->pipe_write_fd, &val, sizeof(val));
}

// === C API 实现 ===
// 直接调用内部核心函数，返回 long long 句柄（失败返回 -1）

void touchcontroller_ios_init(void) {
    // no-op，预留扩展点
}

long long touchcontroller_ios_new(const char* path) {
    if (path == NULL) {
        return -1;
    }
    ios_transport_t* transport = ios_transport_create(path);
    if (transport == NULL) {
        return -1;
    }
    return (long long)transport;
}

int touchcontroller_ios_receive(long long handle, void* buffer, int buffer_length) {
    if (handle <= 0) {
        return -1;
    }
    ios_transport_t* transport = (ios_transport_t*)handle;
    return ios_transport_receive(transport, buffer, buffer_length);
}

void touchcontroller_ios_send(long long handle, const void* buffer, int offset, int length) {
    if (handle <= 0) {
        return;
    }
    ios_transport_t* transport = (ios_transport_t*)handle;
    ios_transport_send(transport, buffer, offset, length);
}

void touchcontroller_ios_destroy(long long handle) {
    if (handle <= 0) {
        return;
    }
    ios_transport_t* transport = (ios_transport_t*)handle;
    ios_transport_destroy(transport);
}

// === JNI API 实现 ===
// 供 Mod 通过 JVM JNI 调用，对应 Transport.kt 中的 external 声明
// init/destroy 直接委托给内部核心函数；
// new 委托给 ios_transport_create（jstring → const char* 转换）；
// send/receive 自行处理消息构造/解析（需调用 JNIEnv 进行 jbyteArray 转换）。

static void throw_exception(JNIEnv* env, const char* msg) {
    (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/Exception"), msg);
}

static void throw_npe(JNIEnv* env, const char* msg) {
    (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/NullPointerException"), msg);
}

JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_init(JNIEnv* env, jclass clazz) {
    // 与 C API 一致：no-op，预留扩展点
    (void)env;
    (void)clazz;
}

JNIEXPORT jlong JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_new(JNIEnv* env, jclass clazz, jstring name) {
    (void)clazz;
    if (name == NULL) {
        throw_npe(env, "Socket path is null");
        return 0;
    }
    // jstring → const char* 转换
    const char* path = (*env)->GetStringUTFChars(env, name, NULL);
    if (path == NULL) {
        throw_exception(env, "Failed to get socket path");
        return 0;
    }
    // 委托给内部核心函数
    ios_transport_t* transport = ios_transport_create(path);
    (*env)->ReleaseStringUTFChars(env, name, path);
    if (transport == NULL) {
        throw_exception(env, "Failed to create transport");
        return 0;
    }
    return (jlong)transport;
}

JNIEXPORT jint JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_receive(JNIEnv* env, jclass clazz, jlong handle, jbyteArray buffer) {
    (void)clazz;
    if (buffer == NULL) {
        throw_npe(env, "Buffer is null");
        return 0;
    }
    ios_transport_t* transport = (ios_transport_t*)handle;
    if (transport == NULL) {
        throw_npe(env, "Transport handle is null");
        return 0;
    }
    if (transport->failed) {
        throw_exception(env, "Transport thread failed");
        return 0;
    }

    // 从 read_buffer 出队一条消息
    pthread_mutex_lock(&transport->read_mutex);
    message_t* message = ring_buffer_dequeue(transport->read_buffer);
    pthread_mutex_unlock(&transport->read_mutex);

    if (message == NULL) {
        return 0;  // 无消息
    }

    // void* → jbyteArray 转换：使用 SetByteArrayRegion 拷贝
    (*env)->SetByteArrayRegion(env, buffer, 0, (jsize)message->size, (const jbyte*)message->data);
    if ((*env)->ExceptionCheck(env)) {
        // ArrayIndexOutOfBoundsException：Java 数组太小
        free_message(message);
        return -1;
    }

    jint result = (jint)message->size;
    free_message(message);
    return result;
}

JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_send(JNIEnv* env, jclass clazz, jlong handle, jbyteArray buffer, jint off, jint len) {
    (void)clazz;
    if (buffer == NULL) {
        throw_npe(env, "Buffer is null");
        return;
    }
    if (len <= 0 || len > UINT8_MAX) {
        throw_exception(env, "Bad message size");
        return;
    }
    ios_transport_t* transport = (ios_transport_t*)handle;
    if (transport == NULL) {
        throw_npe(env, "Transport handle is null");
        return;
    }
    if (transport->failed) {
        throw_exception(env, "Transport thread failed");
        return;
    }

    // 构造消息
    message_t* message = malloc(sizeof(message_t));
    if (message == NULL) {
        throw_exception(env, "Failed to allocate message");
        return;
    }
    message->size = len;
    message->bytes_processed = -1;  // -1 表示尚未写入长度字节
    message->data = malloc(len);
    if (message->data == NULL) {
        free(message);
        throw_exception(env, "Failed to allocate message data");
        return;
    }

    // jbyteArray → void* 转换：使用 GetByteArrayRegion 拷贝
    (*env)->GetByteArrayRegion(env, buffer, off, len, (jbyte*)message->data);
    if ((*env)->ExceptionCheck(env)) {
        // ArrayIndexOutOfBoundsException：off/len 越界
        free_message(message);
        return;
    }

    // 入队 write_buffer
    pthread_mutex_lock(&transport->write_mutex);
    int ret = ring_buffer_enqueue(transport->write_buffer, message);
    pthread_mutex_unlock(&transport->write_mutex);
    if (ret != 0) {
        free_message(message);
        throw_exception(env, "Failed to write message into write buffer");
        return;
    }

    // 写入 pipe 唤醒工作线程
    uint8_t val = 1;
    ret = (int)write(transport->pipe_write_fd, &val, sizeof(val));
    if (ret != sizeof(val)) {
        throw_exception(env, "Failed to kick the worker thread");
        return;
    }
}

JNIEXPORT void JNICALL Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_destroy(JNIEnv* env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    ios_transport_t* transport = (ios_transport_t*)handle;
    if (transport == NULL) {
        return;
    }
    // 委托给内部核心函数
    ios_transport_destroy(transport);
}

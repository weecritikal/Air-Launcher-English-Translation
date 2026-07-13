/*
 * ZeroTier Apple Framework stub 实现
 *
 * 本文件提供 ZeroTierSockets.h API 的桩实现，使项目在没有真实 zt.framework 时也能编译通过。
 *
 * 工作原理：
 *   - 编译时如果存在真实 zt.framework，CMakeLists.txt 会链接真实库，不会使用本 stub
 *   - 如果不存在 zt.framework，CMakeLists.txt 会编译本 stub，所有 API 返回错误码
 *   - 这样 CI 构建不会因缺少 framework 而失败，联机功能仅在运行时报"未集成"错误
 *
 * 要启用真正的联机功能：
 *   1. 从 https://github.com/zerotier/zerotier-sockets-apple-framework 获取 zt.framework
 *   2. 将 zt.framework 放到 Natives/external/zt.framework/（替换 stub 的头文件）
 *   3. 或运行 .github/workflows/build-zt-framework.yml 工作流自动下载
 *   4. 重新构建主项目
 */

/* 确保 C API 版本的 zts_init_set_event_handler 被启用 */
#ifndef ZTS_C_API_ONLY
#define ZTS_C_API_ONLY 1
#endif

#include "ZeroTierSockets.h"
#include <string.h>
#include <stdlib.h>

/* 错误码 */
#ifndef ZTS_ERR_OK
#define ZTS_ERR_OK 0
#define ZTS_ERR_SOCKET -1
#define ZTS_ERR_SERVICE -2
#define ZTS_ERR_ARG -3
#define ZTS_ERR_NO_RESULT -4
#define ZTS_ERR_GENERAL -5
#endif

/* =========================================================================
 * 初始化 API
 * ========================================================================= */

int zts_init_from_storage(const char* path) {
    (void)path;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_event_handler(void (*callback)(void*)) {
    (void)callback;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_tcp_relay(const char* tcp_relay_addr, unsigned short tcp_relay_port) {
    (void)tcp_relay_addr;
    (void)tcp_relay_port;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_tcp_relay(int enabled) {
    (void)enabled;
    return ZTS_ERR_SERVICE;
}

int zts_init_force_tcp_relay(int enabled) {
    (void)enabled;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_port(unsigned short port) {
    (void)port;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_random_port_range(unsigned short start_port, unsigned short end_port) {
    (void)start_port;
    (void)end_port;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_secondary_port(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_port_mapping(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_net_cache(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_peer_cache(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_roots_cache(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_allow_id_cache(unsigned int allowed) {
    (void)allowed;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_roots(const void* roots_data, unsigned int len) {
    (void)roots_data;
    (void)len;
    return ZTS_ERR_SERVICE;
}

int zts_init_set_low_bandwidth_mode(int enabled) {
    (void)enabled;
    return ZTS_ERR_SERVICE;
}

int zts_init_blacklist_if(const char* prefix, unsigned int len) {
    (void)prefix;
    (void)len;
    return ZTS_ERR_SERVICE;
}

/* =========================================================================
 * 节点管理 API
 * ========================================================================= */

int zts_node_start(void) {
    return ZTS_ERR_SERVICE;
}

int zts_node_is_online(void) {
    return 0;
}

uint64_t zts_node_get_id(void) {
    return 0;
}

int zts_node_get_id_pair(char* key, unsigned int* key_dst_len) {
    if (key && key_dst_len) {
        *key_dst_len = 0;
    }
    return ZTS_ERR_SERVICE;
}

int zts_node_get_port(void) {
    return ZTS_ERR_SERVICE;
}

int zts_node_stop(void) {
    return ZTS_ERR_SERVICE;
}

int zts_node_free(void) {
    return ZTS_ERR_SERVICE;
}

/* =========================================================================
 * 网络管理 API
 * ========================================================================= */

uint64_t zts_net_compute_adhoc_id(uint16_t start_port, uint16_t end_port) {
    (void)start_port;
    (void)end_port;
    return 0;
}

int zts_net_join(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

int zts_net_leave(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

int zts_net_transport_is_ready(const uint64_t net_id) {
    (void)net_id;
    return 0;
}

uint64_t zts_net_get_mac(uint64_t net_id) {
    (void)net_id;
    return 0;
}

int zts_net_get_mac_str(uint64_t net_id, char* dst, unsigned int len) {
    (void)net_id;
    if (dst && len > 0) {
        dst[0] = '\0';
    }
    return ZTS_ERR_SERVICE;
}

int zts_net_get_broadcast(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

int zts_net_get_mtu(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

int zts_net_get_name(uint64_t net_id, char* dst, unsigned int len) {
    (void)net_id;
    if (dst && len > 0) {
        dst[0] = '\0';
    }
    return ZTS_ERR_SERVICE;
}

int zts_net_get_status(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

int zts_net_get_type(uint64_t net_id) {
    (void)net_id;
    return ZTS_ERR_SERVICE;
}

/* =========================================================================
 * 地址查询 API
 * ========================================================================= */

int zts_addr_is_assigned(uint64_t net_id, unsigned int family) {
    (void)net_id;
    (void)family;
    return 0;
}

int zts_addr_get(uint64_t net_id, unsigned int family, struct zts_sockaddr_storage* addr) {
    (void)net_id;
    (void)family;
    (void)addr;
    return ZTS_ERR_SERVICE;
}

int zts_addr_get_str(uint64_t net_id, unsigned int family, char* dst, unsigned int len) {
    (void)net_id;
    (void)family;
    if (dst && len > 0) {
        dst[0] = '\0';
    }
    return ZTS_ERR_SERVICE;
}

int zts_addr_get_all(uint64_t net_id, struct zts_sockaddr_storage* addr, unsigned int* count) {
    (void)net_id;
    (void)addr;
    if (count) {
        *count = 0;
    }
    return ZTS_ERR_SERVICE;
}

int zts_addr_compute_rfc4193_str(uint64_t net_id, uint64_t node_id, char* dst, unsigned int len) {
    (void)net_id;
    (void)node_id;
    if (dst && len > 0) {
        dst[0] = '\0';
    }
    return ZTS_ERR_SERVICE;
}

int zts_addr_compute_6plane_str(uint64_t net_id, uint64_t node_id, char* dst, unsigned int len) {
    (void)net_id;
    (void)node_id;
    if (dst && len > 0) {
        dst[0] = '\0';
    }
    return ZTS_ERR_SERVICE;
}

/* =========================================================================
 * BSD Socket API
 * ========================================================================= */

int zts_bsd_socket(int family, int type, int protocol) {
    (void)family;
    (void)type;
    (void)protocol;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_connect(int fd, const struct zts_sockaddr* addr, zts_socklen_t addrlen) {
    (void)fd;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_bind(int fd, const struct zts_sockaddr* addr, zts_socklen_t addrlen) {
    (void)fd;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_listen(int fd, int backlog) {
    (void)fd;
    (void)backlog;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_accept(int fd, struct zts_sockaddr* addr, zts_socklen_t* addrlen) {
    (void)fd;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_setsockopt(int fd, int level, int optname, const void* optval, zts_socklen_t optlen) {
    (void)fd;
    (void)level;
    (void)optname;
    (void)optval;
    (void)optlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_getsockopt(int fd, int level, int optname, void* optval, zts_socklen_t* optlen) {
    (void)fd;
    (void)level;
    (void)optname;
    (void)optval;
    (void)optlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_getsockname(int fd, struct zts_sockaddr* addr, zts_socklen_t* addrlen) {
    (void)fd;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_getpeername(int fd, struct zts_sockaddr* addr, zts_socklen_t* addrlen) {
    (void)fd;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_close(int fd) {
    (void)fd;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_select(int nfds, zts_fd_set* readfds, zts_fd_set* writefds, zts_fd_set* exceptfds, struct zts_timeval* timeout) {
    (void)nfds;
    (void)readfds;
    (void)writefds;
    (void)exceptfds;
    (void)timeout;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_fcntl(int fd, int cmd, int flags) {
    (void)fd;
    (void)cmd;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_poll(struct zts_pollfd* fds, zts_nfds_t nfds, int timeout) {
    (void)fds;
    (void)nfds;
    (void)timeout;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_ioctl(int fd, unsigned long request, void* argp) {
    (void)fd;
    (void)request;
    (void)argp;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_send(int fd, const void* buf, size_t len, int flags) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_sendto(int fd, const void* buf, size_t len, int flags, const struct zts_sockaddr* addr, zts_socklen_t addrlen) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_sendmsg(int fd, const struct zts_msghdr* msg, int flags) {
    (void)fd;
    (void)msg;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_recv(int fd, void* buf, size_t len, int flags) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_recvfrom(int fd, void* buf, size_t len, int flags, struct zts_sockaddr* addr, zts_socklen_t* addrlen) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    (void)addr;
    (void)addrlen;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_recvmsg(int fd, struct zts_msghdr* msg, int flags) {
    (void)fd;
    (void)msg;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_read(int fd, void* buf, size_t len) {
    (void)fd;
    (void)buf;
    (void)len;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_readv(int fd, const struct zts_iovec* iov, int iovcnt) {
    (void)fd;
    (void)iov;
    (void)iovcnt;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_write(int fd, const void* buf, size_t len) {
    (void)fd;
    (void)buf;
    (void)len;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_bsd_writev(int fd, const struct zts_iovec* iov, int iovcnt) {
    (void)fd;
    (void)iov;
    (void)iovcnt;
    return ZTS_ERR_SOCKET;
}

int zts_bsd_shutdown(int fd, int how) {
    (void)fd;
    (void)how;
    return ZTS_ERR_SOCKET;
}

/* =========================================================================
 * 高层 Socket API
 * ========================================================================= */

int zts_socket(int family, int type, int protocol) {
    (void)family;
    (void)type;
    (void)protocol;
    return ZTS_ERR_SOCKET;
}

int zts_connect(int fd, const char* addr, unsigned short port, int timeout_ms) {
    (void)fd;
    (void)addr;
    (void)port;
    (void)timeout_ms;
    return ZTS_ERR_SOCKET;
}

int zts_bind(int fd, const char* addr, unsigned short port) {
    (void)fd;
    (void)addr;
    (void)port;
    return ZTS_ERR_SOCKET;
}

int zts_listen(int fd, int backlog) {
    (void)fd;
    (void)backlog;
    return ZTS_ERR_SOCKET;
}

int zts_accept(int fd, char* remote_addr, int len, unsigned short* remote_port) {
    (void)fd;
    (void)remote_addr;
    (void)len;
    (void)remote_port;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_read(int fd, void* buf, size_t len) {
    (void)fd;
    (void)buf;
    (void)len;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_write(int fd, const void* buf, size_t len) {
    (void)fd;
    (void)buf;
    (void)len;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_send(int fd, const void* buf, size_t len, int flags) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

ssize_t zts_recv(int fd, void* buf, size_t len, int flags) {
    (void)fd;
    (void)buf;
    (void)len;
    (void)flags;
    return ZTS_ERR_SOCKET;
}

int zts_close(int fd) {
    (void)fd;
    return ZTS_ERR_SOCKET;
}

int zts_tcp_server(const char* local_addr, unsigned short local_port, char* remote_addr, int len, unsigned short* remote_port) {
    (void)local_addr;
    (void)local_port;
    (void)remote_addr;
    (void)len;
    (void)remote_port;
    return ZTS_ERR_SOCKET;
}

int zts_tcp_client(const char* remote_addr, unsigned short remote_port) {
    (void)remote_addr;
    (void)remote_port;
    return ZTS_ERR_SOCKET;
}

int zts_udp_server(const char* local_addr, unsigned short local_port) {
    (void)local_addr;
    (void)local_port;
    return ZTS_ERR_SOCKET;
}

int zts_udp_client(const char* remote_addr) {
    (void)remote_addr;
    return ZTS_ERR_SOCKET;
}

/* =========================================================================
 * 工具函数
 * ========================================================================= */

void zts_util_delay(unsigned long milliseconds) {
    (void)milliseconds;
}

int zts_util_get_ip_family(const char* ipstr) {
    (void)ipstr;
    return 0;
}

int zts_util_ipstr_to_saddr(const char* src_ipstr, unsigned short port, struct zts_sockaddr* dstaddr, zts_socklen_t* addrlen) {
    (void)src_ipstr;
    (void)port;
    (void)dstaddr;
    (void)addrlen;
    return ZTS_ERR_ARG;
}

int zts_util_ntop(struct zts_sockaddr* addr, zts_socklen_t addrlen, char* dst_str, int len, unsigned short* port) {
    (void)addr;
    (void)addrlen;
    if (dst_str && len > 0) {
        dst_str[0] = '\0';
    }
    if (port) {
        *port = 0;
    }
    return ZTS_ERR_ARG;
}

/* 全局错误变量 */
int zts_errno = 0;

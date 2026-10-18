#include "CNative.h"
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>

int roam_socket_poll(int fd, int rd, int wr, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = (rd ? POLLIN : 0) | (wr ? POLLOUT : 0) };
    return poll(&p, 1, timeout_ms);
}
int roam_tcp_connect(const char *host, int port, int timeout_ms) {
    char service[8]; snprintf(service, sizeof(service), "%d", port);
    struct addrinfo hints = {0}, *list = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, service, &hints, &list) != 0) return -1;
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    int fd = -1;
    for (struct addrinfo *a = list; a; a = a->ai_next) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        int remaining = timeout_ms - (int)((now.tv_sec-start.tv_sec)*1000 + (now.tv_nsec-start.tv_nsec)/1000000);
        if (remaining <= 0) break;
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int yes = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc == 0) break;
        if (errno == EINPROGRESS && roam_socket_poll(fd, 0, 1, remaining) > 0) {
            int error = 0; socklen_t len = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0) break;
        }
        close(fd); fd = -1;
    }
    freeaddrinfo(list); return fd;
}
void roam_socket_shutdown(int fd) { if (fd >= 0) shutdown(fd, SHUT_RDWR); }
void roam_socket_close(int fd) { if (fd >= 0) close(fd); }
int roam_socket_peer(int fd, char *host, int length) {
    struct sockaddr_storage address; socklen_t size = sizeof(address);
    if (fd < 0 || length <= 0 || getpeername(fd, (struct sockaddr *)&address, &size) != 0) return -1;
    return getnameinfo((struct sockaddr *)&address, size, host, (socklen_t)length, NULL, 0, NI_NUMERICHOST) == 0 ? 0 : -1;
}

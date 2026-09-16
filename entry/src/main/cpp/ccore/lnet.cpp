#include "lnet.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#endif

#include <cstdio>

namespace lcore {

namespace {
bool g_netInit = false;
}

bool NetInitOnce() {
    if (g_netInit) return true;
#ifdef _WIN32
    WSADATA d;
    if (WSAStartup(MAKEWORD(2, 2), &d) != 0) return false;
#endif
    g_netInit = true;
    return true;
}

int TranslateErrno() {
#ifdef _WIN32
    return WSAGetLastError();
#else
    return errno;
#endif
}

std::string LastErrorString() {
#ifdef _WIN32
    return "winsock error";
#else
    return std::strerror(errno);
#endif
}

int SetSockRcvTimeout(int fd, int timeoutMs) {
    struct timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
}

void KillSocket(int fd) {
    if (fd < 0) return;
#ifdef _WIN32
    shutdown((SOCKET)fd, SD_BOTH);
    closesocket((SOCKET)fd);
#else
    shutdown(fd, SHUT_RDWR);
    ::close(fd);
#endif
}

bool SocketIsV6(int fd) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss);
    if (getsockname(fd, reinterpret_cast<struct sockaddr*>(&ss), &len) != 0) return false;
    return ss.ss_family == AF_INET6;
}

int MakeSockAddr(const std::string& ip, int port, struct sockaddr_storage& ss, socklen_t& len) {
    std::memset(&ss, 0, sizeof(ss));
    struct in_addr a4;
    if (inet_pton(AF_INET, ip.c_str(), &a4) == 1) {
        auto* sin = reinterpret_cast<struct sockaddr_in*>(&ss);
        sin->sin_family = AF_INET;
        sin->sin_port = htons(static_cast<uint16_t>(port));
        std::memcpy(&sin->sin_addr, &a4, 4);
        len = sizeof(struct sockaddr_in);
        return 0;
    }
    struct in6_addr a6;
    if (inet_pton(AF_INET6, ip.c_str(), &a6) == 1) {
        auto* sin6 = reinterpret_cast<struct sockaddr_in6*>(&ss);
        sin6->sin6_family = AF_INET6;
        sin6->sin6_port = htons(static_cast<uint16_t>(port));
        std::memcpy(&sin6->sin6_addr, &a6, 16);
        len = sizeof(struct sockaddr_in6);
        return 0;
    }
    return -1;
}

int DialIpPort(const std::string& ip, int port, long long timeoutMs, std::string& errOut) {
    struct sockaddr_storage ss;
    socklen_t slen = 0;
    if (MakeSockAddr(ip, port, ss, slen) != 0) {
        errOut = "invalid dial address";
        return -1;
    }
    bool v6 = (ss.ss_family == AF_INET6);
    int fd = static_cast<int>(socket(ss.ss_family, SOCK_STREAM, 0));
    if (fd < 0) {
        errOut = std::string("socket: ") + LastErrorString();
        return -1;
    }
    if (timeoutMs > 0) {
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
    }
    // Non-blocking connect with select so connect_timeout is honoured.
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket((SOCKET)fd, FIONBIO, &mode);
#else
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
#endif
    int rc = connect(fd, reinterpret_cast<struct sockaddr*>(&ss), slen);
    auto want = TranslateErrno();
#ifdef _WIN32
    if (rc != 0 && want != WSAEWOULDBLOCK && want != WSAEINPROGRESS) {
#else
    if (rc != 0 && want != EINPROGRESS && want != EAGAIN) {
#endif
        errOut = std::string("connect: ") + LastErrorString();
        KillSocket(fd);
        return -1;
    }
    if (rc != 0) {
        int sr = 0;
#ifdef _WIN32
        // select() can block indefinitely inside a worker thread on some Winsock
        // stacks; WSAPoll honours its timeout reliably.
        struct pollfd pfd;
        pfd.fd = SOCKET_CAST(fd);
        pfd.events = POLLOUT;
        pfd.revents = 0;
        sr = WSAPoll(&pfd, 1, static_cast<INT>(timeoutMs));
#else
        fd_set wf;
        FD_ZERO(&wf);
        FD_SET(fd, &wf);
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        sr = select(fd + 1, nullptr, &wf, nullptr, &tv);
#endif
        if (sr <= 0) {
            errOut = sr == 0 ? "connection timeout" : std::string("poll: ") + LastErrorString();
            KillSocket(fd);
            return -1;
        }
        int soerr = 0;
        socklen_t sl = sizeof(soerr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&soerr), &sl);
        if (soerr != 0) {
            errOut = std::string("connect: ") + LastErrorString();
            KillSocket(fd);
            return -1;
        }
    }
#ifdef _WIN32
    u_long mode2 = 0;
    ioctlsocket((SOCKET)fd, FIONBIO, &mode2);
#else
    int fl2 = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl2 & ~O_NONBLOCK);
#endif
    if (v6) {
        // RFC 3542 vs 2292: use the working V6ONLY definition for the platform.
#ifdef IPV6_V6ONLY
        int on = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<const char*>(&on), sizeof(on));
#endif
    }
    return fd;
}

int DialHostPort(const std::string& hostOrIp, int port, long long timeoutMs, std::string& errOut) {
    struct sockaddr_storage ss;
    socklen_t slen = 0;
    if (MakeSockAddr(hostOrIp, port, ss, slen) == 0) {
        return DialIpPort(hostOrIp, port, timeoutMs, errOut);
    }
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = nullptr;
    std::string portStr = std::to_string(port);
    int gai = getaddrinfo(hostOrIp.c_str(), portStr.c_str(), &hints, &res);
    if (gai != 0) {
        errOut = std::string("resolve ") + hostOrIp + ": " + gai_strerror(gai);
        return -1;
    }
    std::string chosen;  // prefer IPv4
    for (auto* r = res; r; r = r->ai_next) {
        char buf[INET6_ADDRSTRLEN] = {0};
        if (r->ai_family == AF_INET) {
            inet_ntop(AF_INET, &reinterpret_cast<struct sockaddr_in*>(r->ai_addr)->sin_addr, buf, sizeof(buf));
            chosen = buf;
            break;
        }
    }
    if (chosen.empty()) {
        for (auto* r = res; r; r = r->ai_next) {
            char buf[INET6_ADDRSTRLEN] = {0};
            if (r->ai_family == AF_INET6) {
                inet_ntop(AF_INET6, &reinterpret_cast<struct sockaddr_in6*>(r->ai_addr)->sin6_addr, buf, sizeof(buf));
                chosen = buf;
                break;
            }
        }
    }
    freeaddrinfo(res);
    if (chosen.empty()) {
        errOut = "no usable address for " + hostOrIp;
        return -1;
    }
    return DialIpPort(chosen, port, timeoutMs, errOut);
}

int CreateListener(const std::string& hostPort, int acceptBacklog, std::string& errOut) {
    std::string host;
    int port = 0;
    size_t colon = hostPort.rfind(':');
    if (colon == std::string::npos) {
        errOut = "invalid listen address (missing ':')";
        return -1;
    }
    host = hostPort.substr(0, colon);
    port = std::atoi(hostPort.c_str() + colon + 1);
    if (port <= 0) {
        errOut = "invalid listen port";
        return -1;
    }
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo* res = nullptr;
    std::string portStr = std::to_string(port);
    const char* node = (host.empty() || host == "0.0.0.0" || host == "::") ? nullptr : host.c_str();
    int gai = getaddrinfo(node, portStr.c_str(), &hints, &res);
    if (gai != 0) {
        errOut = std::string("resolve listen address: ") + gai_strerror(gai);
        return -1;
    }
    int fd = -1;
    for (auto* r = res; r; r = r->ai_next) {
        fd = static_cast<int>(socket(r->ai_family, r->ai_socktype, r->ai_protocol));
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&one), sizeof(one));
#ifdef IPV6_V6ONLY
        if (r->ai_family == AF_INET6) {
            int v6on = r->ai_addr->sa_family == AF_INET6 ? 1 : 0;
            (void)v6on;
        }
#endif
        if (bind(fd, r->ai_addr, static_cast<socklen_t>(r->ai_addrlen)) != 0) {
            LCLOSE_SOCKET(fd);
            fd = -1;
            errOut = std::string("bind ") + hostPort + ": " + LastErrorString();
            continue;
        }
        if (listen(fd, acceptBacklog) != 0) {
            errOut = std::string("listen ") + hostPort + ": " + LastErrorString();
            LCLOSE_SOCKET(fd);
            fd = -1;
            continue;
        }
        break;
    }
    if (res) freeaddrinfo(res);
    if (fd < 0 && errOut.empty()) errOut = "no usable listen address";
    return fd;
}

int AcceptOne(int lfd) {
#ifdef _WIN32
    return static_cast<int>(accept((SOCKET)lfd, nullptr, nullptr));
#else
    return static_cast<int>(accept(lfd, nullptr, nullptr));
#endif
}

bool WriteAll(int fd, const char* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n = LSend(fd, data + off, static_cast<int>(len - off), 0);
        if (n <= 0) {
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

bool WriteAll(int fd, const std::string& data) {
    return WriteAll(fd, data.data(), data.size());
}

std::string PeerAddr(int fd) {
    if (fd < 0) return "-";
    struct sockaddr_storage ss;
    socklen_t sl = static_cast<socklen_t>(sizeof(ss));
    std::memset(&ss, 0, sizeof(ss));
    if (LGETPEERNAME(fd, reinterpret_cast<struct sockaddr*>(&ss), &sl) != 0) {
        return "-";
    }
    char buf[INET6_ADDRSTRLEN] = {0};
    if (ss.ss_family == AF_INET) {
        inet_ntop(AF_INET, &reinterpret_cast<struct sockaddr_in*>(&ss)->sin_addr, buf, sizeof(buf));
        return std::string(buf) + ":" + std::to_string(ntohs(reinterpret_cast<struct sockaddr_in*>(&ss)->sin_port));
    } else if (ss.ss_family == AF_INET6) {
        inet_ntop(AF_INET6, &reinterpret_cast<struct sockaddr_in6*>(&ss)->sin6_addr, buf, sizeof(buf));
        return "[" + std::string(buf) + "]:" + std::to_string(ntohs(reinterpret_cast<struct sockaddr_in6*>(&ss)->sin6_port));
    }
    return "-";
}

}  // namespace lcore
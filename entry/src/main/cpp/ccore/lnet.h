// Portable socket shims: winsock on _WIN32, POSIX otherwise. The portable
// core is compiled for both the OHOS emulator and a Windows host smoke build.
#ifndef LCORE_LNET_H
#define LCORE_LNET_H

#include <cstdint>
#include <string>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#define LCLOSE_SOCKET(fd) closesocket((SOCKET)(fd))
#define SOCKET_CAST(fd) ((SOCKET)(fd))
#define LGETPEERNAME(fd, sa, len) getpeername((SOCKET)(fd), (sa), (len))
using socklen_t = int;
#else
#define LCLOSE_SOCKET(fd) close(fd)
#define SOCKET_CAST(fd) (fd)
#define LGETPEERNAME(fd, sa, len) getpeername((fd), (sa), (len))
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace lcore {

inline int LSend(int fd, const char* buf, int len, int flags) {
    return static_cast<int>(send(SOCKET_CAST(fd), buf, len, flags));
}
inline int LRecv(int fd, char* buf, int len, int flags) {
    return static_cast<int>(recv(SOCKET_CAST(fd), buf, len, flags));
}
inline void LShutdown(int fd, int how) {
#ifdef _WIN32
    shutdown((SOCKET)(fd), how);
#else
    shutdown(fd, how);
#endif
}

// Call once early. No-op on POSIX; WSAStartup on Windows.
bool NetInitOnce();

int TranslateErrno();

// Sets SO_RCVTIMEO in milliseconds (0 disables). Returns 0 on success.
int SetSockRcvTimeout(int fd, int timeoutMs);

// Non-blocking TCP connect to ip:port. Returns fd or -1 (errOut filled).
int DialIpPort(const std::string& ip, int port, long long timeoutMs, std::string& errOut);

// Like DialIpPort but takes pre-binary address family hints from caller if needed.
int DialHostPort(const std::string& hostOrIp, int port, long long timeoutMs, std::string& errOut);

// Bind+listen TCP on host:port (host "" = all). Returns fd or -1.
int CreateListener(const std::string& hostPort, int acceptBacklog, std::string& errOut);

// accept() wrapper producing a connected fd or -1.
int AcceptOne(int lfd);
void KillSocket(int fd);
bool SocketIsV6(int fd);

// Formats "host:port" into a sockaddr for dialing.
int MakeSockAddr(const std::string& ip, int port, struct sockaddr_storage& ss, socklen_t& len);

std::string LastErrorString();

// Full-buffer writes.
bool WriteAll(int fd, const std::string& data);
bool WriteAll(int fd, const char* data, size_t len);

// "ip:port" (or "-") of the connected peer, for log labels / stats.
std::string PeerAddr(int fd);

}  // namespace lcore

#endif  // LCORE_LNET_H
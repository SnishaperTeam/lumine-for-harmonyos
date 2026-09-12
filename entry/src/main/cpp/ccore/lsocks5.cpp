#include "lsocks5.h"

#include <cstdint>
#include <cstring>
#include <string>

#include "lcore.h"
#include "lnet.h"
#include "lroute.h"
#include "ltunnel.h"
#include "ltypes.h"

namespace lcore {

namespace {

constexpr unsigned char kSocksVersion = 0x05;
constexpr unsigned char kReplyNoAuth = 0x00;
constexpr unsigned char kSocks5ReplySuccess[10] = {0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
constexpr unsigned char kSocks5ReplyServerFailure[10] = {0x05, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
constexpr unsigned char kSocks5ReplyHostUnreachable[10] = {0x05, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
constexpr unsigned char kSocks5ReplyCmdNotSupported[10] = {0x05, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
constexpr unsigned char kSocks5ReplyAtypNotSupported[10] = {0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};

bool SendReply(int fd, const unsigned char reply[10]) {
    return WriteAll(fd, reinterpret_cast<const char*>(reply), 10);
}

}  // namespace

void HandleSocks5(int clientFd) {
    Logger& lg = Logger::Get();
    lg.Log(LogLevel::Info, "SOCKS5 new client connection from " + PeerAddr(clientFd));

    SetSockRcvTimeout(clientFd, 10000);

    // Greeting: VER NMETHODS METHODS...
    std::string greeting = RecvBytes(clientFd, 2, 5000);
    if (greeting.size() < 2) {
        lg.Log(LogLevel::Warn, "SOCKS5 greeting too short");
        KillSocket(clientFd);
        return;
    }
    if (static_cast<unsigned char>(greeting[0]) != kSocksVersion) {
        lg.Log(LogLevel::Warn, "SOCKS5 unsupported version " + std::to_string(static_cast<int>(static_cast<unsigned char>(greeting[0]))));
        KillSocket(clientFd);
        return;
    }
    int nmethods = static_cast<unsigned char>(greeting[1]);
    std::string methods = RecvBytes(clientFd, static_cast<std::size_t>(nmethods), 5000);
    if (methods.size() < static_cast<std::size_t>(nmethods)) {
        lg.Log(LogLevel::Warn, "SOCKS5 greeting methods truncated");
        KillSocket(clientFd);
        return;
    }
    const char noAuth[2] = {static_cast<char>(kSocksVersion), static_cast<char>(kReplyNoAuth)};
    if (!WriteAll(clientFd, noAuth, 2)) {
        KillSocket(clientFd);
        return;
    }

    // Request: VER CMD RSV ATYP DST.ADDR DST.PORT
    std::string rhead = RecvBytes(clientFd, 4, 5000);
    if (rhead.size() < 4) {
        lg.Log(LogLevel::Warn, "SOCKS5 request truncated");
        KillSocket(clientFd);
        return;
    }
    if (static_cast<unsigned char>(rhead[0]) != kSocksVersion) {
        SendReply(clientFd, kSocks5ReplyServerFailure);
        KillSocket(clientFd);
        return;
    }
    unsigned char cmd = static_cast<unsigned char>(rhead[1]);
    unsigned char atyp = static_cast<unsigned char>(rhead[3]);

    if (cmd != 0x01) {  // only CONNECT supported
        lg.Log(LogLevel::Info, "SOCKS5 unsupported command " + std::to_string(cmd));
        SendReply(clientFd, kSocks5ReplyCmdNotSupported);
        KillSocket(clientFd);
        return;
    }

    std::string dstHost;
    if (atyp == 0x01) {  // IPv4
        std::string a = RecvBytes(clientFd, 4, 5000);
        if (a.size() < 4) {
            KillSocket(clientFd);
            return;
        }
        char buf[INET_ADDRSTRLEN] = {0};
        struct in_addr in;
        std::memcpy(&in, a.data(), 4);
        inet_ntop(AF_INET, &in, buf, sizeof(buf));
        dstHost = buf;
    } else if (atyp == 0x03) {  // domain
        std::string l = RecvBytes(clientFd, 1, 5000);
        if (l.size() < 1) {
            KillSocket(clientFd);
            return;
        }
        int dlen = static_cast<unsigned char>(l[0]);
        std::string d = RecvBytes(clientFd, static_cast<std::size_t>(dlen), 5000);
        if (d.size() < static_cast<std::size_t>(dlen)) {
            KillSocket(clientFd);
            return;
        }
        dstHost = d;
    } else if (atyp == 0x04) {  // IPv6
        std::string a = RecvBytes(clientFd, 16, 5000);
        if (a.size() < 16) {
            KillSocket(clientFd);
            return;
        }
        char buf[INET6_ADDRSTRLEN] = {0};
        struct in6_addr in6;
        std::memcpy(&in6, a.data(), 16);
        inet_ntop(AF_INET6, &in6, buf, sizeof(buf));
        dstHost = buf;
    } else {
        lg.Log(LogLevel::Warn, "SOCKS5 unsupported ATYP " + std::to_string(atyp));
        SendReply(clientFd, kSocks5ReplyAtypNotSupported);
        KillSocket(clientFd);
        return;
    }

    std::string portRaw = RecvBytes(clientFd, 2, 5000);
    if (portRaw.size() < 2) {
        KillSocket(clientFd);
        return;
    }
    int dstPort = (static_cast<unsigned char>(portRaw[0]) << 8) | static_cast<unsigned char>(portRaw[1]);

    if (dstHost.empty() || dstPort == 0) {
        SendReply(clientFd, kSocks5ReplyCmdNotSupported);
        KillSocket(clientFd);
        return;
    }

    std::string originHost = dstHost;
    int originPort = dstPort;
    bool isIP = IsIP(dstHost);

    RouteResult r = Route(GetCoreConfig(), originHost, isIP, false);
    if (r.failed) {
        lg.Log(LogLevel::Error, "SOCKS5 route " + originHost + ": failed to resolve/map");
        SendReply(clientFd, kSocks5ReplyHostUnreachable);
        KillSocket(clientFd);
        return;
    }
    if (r.blocked) {
        lg.Log(LogLevel::Info, "SOCKS5 blocked " + originHost);
        SendReply(clientFd, kSocks5ReplyHostUnreachable);
        Stats().blocked++;
        KillSocket(clientFd);
        return;
    }

    std::string label = "SOCKS5 " + PeerAddr(clientFd) + " -- " + originHost + ":" + std::to_string(originPort) + " -> " + r.dstHost;

    if (!SendReply(clientFd, kSocks5ReplySuccess)) {
        KillSocket(clientFd);
        return;
    }

    Tunnel(clientFd, -1, r.policy, r.dstHost, dstPort, originHost, originPort, label, "");
}

}  // namespace lcore
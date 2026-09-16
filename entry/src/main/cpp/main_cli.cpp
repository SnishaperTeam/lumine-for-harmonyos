#include <atomic>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#include "ccore/lcore.h"
#include "ccore/lnet.h"
#include "ccore/ltun.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

using namespace lcore;

namespace {

int g_echoPort = 18130;
int g_socks5Port = 1080;
int g_httpPort = 1225;

void CloseFd(int fd) {
#ifdef _WIN32
    closesocket((SOCKET)fd);
#else
    ::close(fd);
#endif
}

std::string ReadExact(int fd, std::size_t want, std::string& err) {
    std::string buf;
    char tmp[4096];
    while (buf.size() < want) {
        int n = LRecv(fd, tmp, static_cast<int>(sizeof(tmp)), 0);
        if (n <= 0) {
            err = "read: " + LastErrorString() + " (got " + std::to_string(buf.size()) + " of " + std::to_string(want) + ")";
            break;
        }
        buf.append(tmp, static_cast<std::size_t>(n));
    }
    return buf;
}

std::string ReadAllToDelim(int fd, const std::string& delim, std::string& err) {
    std::string buf;
    char tmp[1024];
    while (buf.find(delim) == std::string::npos) {
        int n = LRecv(fd, tmp, static_cast<int>(sizeof(tmp)), 0);
        if (n <= 0) {
            err = "read: " + LastErrorString();
            break;
        }
        buf.append(tmp, static_cast<std::size_t>(n));
    }
    return buf;
}

void EchoServer(int lfd) {
    for (;;) {
        int c = AcceptOne(lfd);
        if (c < 0) break;
        std::thread([c] {
            char buf[4096];
            for (;;) {
                int n = LRecv(c, buf, static_cast<int>(sizeof(buf)), 0);
                if (n <= 0) break;
                if (!WriteAll(c, buf, static_cast<std::size_t>(n))) break;
            }
            KillSocket(c);
        }).detach();
    }
}

bool Socks5RoundTrip(int sockPort, int echoPort) {
    std::string err;
    int s5 = DialIpPort("127.0.0.1", sockPort, 3000, err);
    if (s5 < 0) {
        std::printf("  socks5 dial: %s\n", err.c_str());
        return false;
    }
    const char greeting[3] = {0x05, 0x01, 0x00};
    if (!WriteAll(s5, greeting, 3)) { CloseFd(s5); return false; }
    if (ReadExact(s5, 2, err) != std::string("\x05\x00", 2)) {
        std::printf("  socks5 greeting: %s\n", err.c_str());
        CloseFd(s5);
        return false;
    }
    char req[10];
    req[0] = 0x05; req[1] = 0x01; req[2] = 0x00; req[3] = 0x01;
    req[4] = 127; req[5] = 0; req[6] = 0; req[7] = 1;
    req[8] = static_cast<char>((echoPort >> 8) & 0xFF);
    req[9] = static_cast<char>(echoPort & 0xFF);
    if (!WriteAll(s5, req, 10)) { CloseFd(s5); return false; }
    std::string rep = ReadExact(s5, 10, err);
    if (rep.size() < 10 || rep[0] != 5 || rep[1] != 0) {
        std::printf("  socks5 connect reply: %s\n", rep.empty() ? err.c_str() : "failed");
        CloseFd(s5);
        return false;
    }
    const std::string payload = "ping-through-socks5";
    if (!WriteAll(s5, payload) || ReadExact(s5, payload.size(), err) != payload) {
        std::printf("  socks5 echo: %s\n", err.c_str());
        CloseFd(s5);
        return false;
    }
    CloseFd(s5);
    return true;
}

bool HttpConnectRoundTrip(int httpPort, int echoPort) {
    std::string err;
    int h = DialIpPort("127.0.0.1", httpPort, 3000, err);
    if (h < 0) {
        std::printf("  http dial: %s\n", err.c_str());
        return false;
    }
    std::string req = "CONNECT 127.0.0.1:" + std::to_string(echoPort) + " HTTP/1.1\r\nHost: 127.0.0.1:" +
                      std::to_string(echoPort) + "\r\n\r\n";
    if (!WriteAll(h, req)) { CloseFd(h); return false; }
    std::string head = ReadAllToDelim(h, "\r\n\r\n", err);
    if (head.find("200") == std::string::npos) {
        std::printf("  http connect reply: %s\n", head.empty() ? err.c_str() : head.substr(0, 120).c_str());
        CloseFd(h);
        return false;
    }
    const std::string payload = "ping-through-http-connect";
    if (!WriteAll(h, payload) || ReadExact(h, payload.size(), err) != payload) {
        std::printf("  http echo: %s\n", err.c_str());
        CloseFd(h);
        return false;
    }
    CloseFd(h);
    return true;
}

// ------------------------- TUN engine host simulation ------------------------
// The TUN fd is emulated with a connected UDP socket: every datagram is one IP
// packet in either direction, so the whole engine can run on the host.

namespace tunsim {

const uint8_t kClientIp[4] = {172, 19, 0, 10};
const uint8_t kDnsIp[4] = {172, 19, 0, 2};
constexpr uint16_t kClientSport = 40000;
constexpr uint16_t kClientUport = 50000;
constexpr uint32_t kClientIsn = 1000;

uint16_t Cksum(const unsigned char* d, std::size_t len) {
    uint32_t s = 0;
    for (std::size_t i = 0; i + 1 < len; i += 2) s += (d[i] << 8) | d[i + 1];
    if (len & 1) s += static_cast<uint32_t>(d[len - 1] << 8);
    while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
    return static_cast<uint16_t>(~s);
}

uint16_t L4Cksum(const uint8_t* src, const uint8_t* dst, const std::vector<unsigned char>& l4,
                 uint8_t proto) {
    std::vector<unsigned char> buf;
    buf.reserve(20 + l4.size() + 1);
    buf.insert(buf.end(), src, src + 4);
    buf.insert(buf.end(), dst, dst + 4);
    buf.push_back(0);
    buf.push_back(proto);
    buf.push_back(static_cast<unsigned char>((l4.size() >> 8) & 0xFF));
    buf.push_back(static_cast<unsigned char>(l4.size() & 0xFF));
    buf.insert(buf.end(), l4.begin(), l4.end());
    if (buf.size() & 1) buf.push_back(0);
    return Cksum(buf.data(), buf.size());
}

std::vector<unsigned char> BuildTcp(const uint8_t* dstIp, int dstPort, uint32_t seq, uint32_t ack,
                                    uint8_t flags, const std::string& payload) {
    std::vector<unsigned char> l4(20 + payload.size(), 0);
    l4[0] = static_cast<unsigned char>(kClientSport >> 8);
    l4[1] = static_cast<unsigned char>(kClientSport & 0xFF);
    l4[2] = static_cast<unsigned char>(dstPort >> 8);
    l4[3] = static_cast<unsigned char>(dstPort & 0xFF);
    l4[4] = static_cast<unsigned char>(seq >> 24);
    l4[5] = static_cast<unsigned char>((seq >> 16) & 0xFF);
    l4[6] = static_cast<unsigned char>((seq >> 8) & 0xFF);
    l4[7] = static_cast<unsigned char>(seq & 0xFF);
    l4[8] = static_cast<unsigned char>(ack >> 24);
    l4[9] = static_cast<unsigned char>((ack >> 16) & 0xFF);
    l4[10] = static_cast<unsigned char>((ack >> 8) & 0xFF);
    l4[11] = static_cast<unsigned char>(ack & 0xFF);
    l4[12] = 0x50;
    l4[13] = flags;
    l4[14] = 0xFF;
    l4[15] = 0xFF;
    std::memcpy(l4.data() + 20, payload.data(), payload.size());
    uint16_t ck = L4Cksum(kClientIp, dstIp, l4, 6);
    l4[16] = static_cast<unsigned char>(ck >> 8);
    l4[17] = static_cast<unsigned char>(ck & 0xFF);

    std::vector<unsigned char> out(20 + l4.size(), 0);
    out[0] = 0x45;
    out[8] = 64;
    out[9] = 6;
    std::memcpy(&out[12], kClientIp, 4);
    std::memcpy(&out[16], dstIp, 4);
    out[2] = static_cast<unsigned char>((out.size() >> 8) & 0xFF);
    out[3] = static_cast<unsigned char>(out.size() & 0xFF);
    std::memcpy(out.data() + 20, l4.data(), l4.size());
    uint16_t ic = Cksum(out.data(), 20);
    out[10] = static_cast<unsigned char>(ic >> 8);
    out[11] = static_cast<unsigned char>(ic & 0xFF);
    return out;
}

std::vector<unsigned char> BuildUdp(const uint8_t* dstIp, int dstPort, const std::string& payload) {
    std::vector<unsigned char> l4(8 + payload.size(), 0);
    l4[0] = static_cast<unsigned char>(kClientUport >> 8);
    l4[1] = static_cast<unsigned char>(kClientUport & 0xFF);
    l4[2] = static_cast<unsigned char>(dstPort >> 8);
    l4[3] = static_cast<unsigned char>(dstPort & 0xFF);
    l4[4] = static_cast<unsigned char>((l4.size() >> 8) & 0xFF);
    l4[5] = static_cast<unsigned char>(l4.size() & 0xFF);
    std::memcpy(l4.data() + 8, payload.data(), payload.size());
    uint16_t ck = L4Cksum(kClientIp, dstIp, l4, 17);
    l4[6] = static_cast<unsigned char>(ck >> 8);
    l4[7] = static_cast<unsigned char>(ck & 0xFF);

    std::vector<unsigned char> out(20 + l4.size(), 0);
    out[0] = 0x45;
    out[8] = 64;
    out[9] = 17;
    std::memcpy(&out[12], kClientIp, 4);
    std::memcpy(&out[16], dstIp, 4);
    out[2] = static_cast<unsigned char>((out.size() >> 8) & 0xFF);
    out[3] = static_cast<unsigned char>(out.size() & 0xFF);
    std::memcpy(out.data() + 20, l4.data(), l4.size());
    uint16_t ic = Cksum(out.data(), 20);
    out[10] = static_cast<unsigned char>(ic >> 8);
    out[11] = static_cast<unsigned char>(ic & 0xFF);
    return out;
}

struct Pkt {
    int proto = 0;
    uint8_t flags = 0;
    uint32_t seq = 0;
    uint32_t ack = 0;
    std::string payload;
    uint16_t sport = 0;
    uint16_t dport = 0;
    bool valid = false;
};

bool SendPkt(SOCKET s, const std::vector<unsigned char>& pkt) {
    return send(s, reinterpret_cast<const char*>(pkt.data()),
                static_cast<int>(pkt.size()), 0) == static_cast<int>(pkt.size());
}

Pkt Parse(const std::vector<unsigned char>& p) {
    Pkt r;
    if (p.size() < 24 || p[0] >> 4 != 4) return r;
    if (std::memcmp(&p[16], kClientIp, 4) != 0) return r;  // must be addressed to us
    int ihl = (p[0] & 0x0F) * 4;
    if (static_cast<int>(p.size()) < ihl + 20) return r;
    r.proto = p[9];
    const unsigned char* l4 = p.data() + ihl;
    if (r.proto == 6) {
        r.sport = static_cast<uint16_t>((l4[0] << 8) | l4[1]);
        r.dport = static_cast<uint16_t>((l4[2] << 8) | l4[3]);
        r.seq = (static_cast<uint32_t>(l4[4]) << 24) | (static_cast<uint32_t>(l4[5]) << 16) |
                (static_cast<uint32_t>(l4[6]) << 8) | l4[7];
        r.ack = (static_cast<uint32_t>(l4[8]) << 24) | (static_cast<uint32_t>(l4[9]) << 16) |
                (static_cast<uint32_t>(l4[10]) << 8) | l4[11];
        int off = (l4[12] >> 4) * 4;
        int total = static_cast<int>(p.size()) - ihl;
        if (off >= 20 && off <= total) r.payload.assign(reinterpret_cast<const char*>(l4) + off,
                                                        static_cast<std::size_t>(total - off));
        r.flags = l4[13];
        r.valid = true;
    } else if (r.proto == 17) {
        r.sport = static_cast<uint16_t>((l4[0] << 8) | l4[1]);
        r.dport = static_cast<uint16_t>((l4[2] << 8) | l4[3]);
        int ulen = (l4[4] << 8) | l4[5];
        if (ulen >= 8 && ulen <= static_cast<int>(p.size()) - ihl) {
            r.payload.assign(reinterpret_cast<const char*>(l4) + 8, static_cast<std::size_t>(ulen - 8));
        }
        r.valid = true;
    }
    return r;
}

// Blocks until a packet matching pred arrives or maxLoops timeouts elapse.
template <typename Pred>
Pkt ExpectPacket(SOCKET s, int timeoutMs, int maxLoops, Pred pred, const char* what) {
    char buf[65535];
    for (int i = 0; i < maxLoops; ++i) {
        int n = static_cast<int>(recv(s, buf, sizeof(buf), 0));
        if (n < 0) {
            int e = WSAGetLastError();
            if (e == WSAETIMEDOUT || e == WSAEWOULDBLOCK) continue;
            std::printf("  tun %s: recv error %d\n", what, e);
            return Pkt{};
        }
        if (n == 0) {
            std::printf("  tun %s: recv closed\n", what);
            return Pkt{};
        }
        std::vector<unsigned char> raw(reinterpret_cast<unsigned char*>(buf),
                                       reinterpret_cast<unsigned char*>(buf) + n);
        Pkt p = Parse(raw);
        if (p.valid && pred(p)) return p;
    }
    std::printf("  tun %s: timed out after %d loops\n", what, maxLoops);
    return Pkt{};
}

void UdpEchoServer(int port, std::atomic<bool>* run) {
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a;
    std::memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(static_cast<u_short>(port));
    if (bind(s, reinterpret_cast<struct sockaddr*>(&a), sizeof(a)) != 0) {
        closesocket(s);
        return;
    }
    char buf[4096];
    while (run->load()) {
        struct sockaddr_in from;
        int flen = sizeof(from);
        int n = recvfrom(s, buf, sizeof(buf), 0, reinterpret_cast<struct sockaddr*>(&from), &flen);
        if (n <= 0) break;
        sendto(s, buf, n, 0, reinterpret_cast<struct sockaddr*>(&from), flen);
    }
    closesocket(s);
}

bool RunTunTests(int tcpEchoPort) {
    Logger::Get().ResetRing();
    // UDP echo server on an ephemeral port.
    SOCKET probe = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in pa;
    std::memset(&pa, 0, sizeof(pa));
    pa.sin_family = AF_INET;
    pa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    pa.sin_port = 0;
    bind(probe, reinterpret_cast<struct sockaddr*>(&pa), sizeof(pa));
    int plen = sizeof(pa);
    getsockname(probe, reinterpret_cast<struct sockaddr*>(&pa), &plen);
    int udpEchoPort = ntohs(pa.sin_port);
    closesocket(probe);
    std::atomic<bool> udpRun{true};
    std::thread udpThr(UdpEchoServer, udpEchoPort, &udpRun);

    // TUN channel: two connected UDP sockets.
    SOCKET tunSide = socket(AF_INET, SOCK_DGRAM, 0);
    SOCKET testSide = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in ta;
    std::memset(&ta, 0, sizeof(ta));
    ta.sin_family = AF_INET;
    ta.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ta.sin_port = 0;
    bind(tunSide, reinterpret_cast<struct sockaddr*>(&ta), sizeof(ta));
    struct sockaddr_in tb = ta;
    bind(testSide, reinterpret_cast<struct sockaddr*>(&tb), sizeof(tb));
    int blen = sizeof(tb);
    getsockname(testSide, reinterpret_cast<struct sockaddr*>(&tb), &blen);
    connect(tunSide, reinterpret_cast<struct sockaddr*>(&tb), sizeof(tb));
    struct sockaddr_in ta2 = ta;
    int alen = sizeof(ta2);
    getsockname(tunSide, reinterpret_cast<struct sockaddr*>(&ta2), &alen);
    connect(testSide, reinterpret_cast<struct sockaddr*>(&ta2), sizeof(ta2));

    // Give the engine-side socket a receive timeout so StopTun can drain.
    int rcvto = 2000;
    setsockopt(tunSide, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&rcvto), sizeof(rcvto));
    int testto = 1000;
    setsockopt(testSide, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&testto), sizeof(testto));

    std::string err = StartTun(static_cast<int>(tunSide));
    if (!err.empty()) {
        std::printf("  tun start: %s\n", err.c_str());
        udpRun.store(false);
        closesocket(tunSide);
        closesocket(testSide);
        udpThr.detach();
        return false;
    }

    bool all = true;
    const uint8_t loop[4] = {127, 0, 0, 1};
    const uint8_t finSeq = 0;

    // ---- TCP: handshake + echo + teardown ----
    uint32_t seq = kClientIsn;
    SendPkt(testSide, BuildTcp(loop, tcpEchoPort, seq, 0, 0x02, ""));
    Pkt synAck = ExpectPacket(testSide, 3000, 15, [](const Pkt& p) {
        return p.proto == 6 && (p.flags & 0x12) == 0x12;
    }, "syn-ack");
    if (!synAck.valid) {
        all = false;
    } else {
        uint32_t engineIsn = synAck.seq;
        uint32_t clientAck = engineIsn + 1;
        seq = kClientIsn + 1;
        SendPkt(testSide, BuildTcp(loop, tcpEchoPort, seq, clientAck, 0x10, ""));
        const std::string payload = "TUN-TCP-ECHO-PROBE";
        SendPkt(testSide, BuildTcp(loop, tcpEchoPort, seq, clientAck, 0x18, payload));
        seq += static_cast<uint32_t>(payload.size());

        std::string echoed;
        bool gotFin = false;
        bool finSent = false;
        for (int i = 0; i < 12 && (echoed.size() < payload.size() || !gotFin); ++i) {
            if (echoed.size() >= payload.size() && !finSent) {
                finSent = true;
                SendPkt(testSide, BuildTcp(loop, tcpEchoPort, seq, 0, 0x11, ""));
            }
            char buf[65535];
            int n = static_cast<int>(recv(testSide, buf, sizeof(buf), 0));
            if (n < 0) {
                int e = WSAGetLastError();
                if (e == WSAETIMEDOUT || e == WSAEWOULDBLOCK) continue;
                break;
            }
            if (n == 0) break;
            std::vector<unsigned char> raw(reinterpret_cast<unsigned char*>(buf),
                                           reinterpret_cast<unsigned char*>(buf) + n);
            Pkt p = Parse(raw);
            if (!p.valid || p.proto != 6) continue;
            SendPkt(testSide,
                    BuildTcp(loop, tcpEchoPort, seq, p.seq + static_cast<uint32_t>(p.payload.size()) +
                             ((p.flags & 0x01) ? 1u : 0u), 0x10, ""));
            echoed += p.payload;
            if (p.flags & 0x01) gotFin = true;
        }
        if (echoed.find(payload) == std::string::npos) {
            std::printf("  tun tcp echo: got \"%s\"\n", echoed.substr(0, 60).c_str());
            all = false;
        }
        if (!gotFin) {
            std::printf("  tun tcp: no FIN from engine\n");
            all = false;
        }
    }

    // ---- UDP NAT round trip ----
    SendPkt(testSide, BuildUdp(loop, udpEchoPort, "TUN-UDP-ECHO-PROBE"));
    Pkt urep = ExpectPacket(testSide, 3000, 10, [](const Pkt& p) {
        return p.proto == 17 && p.payload.find("TUN-UDP-ECHO-PROBE") != std::string::npos;
    }, "udp-echo");
    if (!urep.valid) {
        std::printf("  tun udp echo: no reply\n");
        all = false;
    }

    // ---- DNS hijack (172.19.0.2:53) ----
    std::string q = std::string("\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                                "\x09localhost\x00\x00\x01\x00\x01", 27);
    std::vector<unsigned char> dnsPkt = BuildUdp(kDnsIp, 53, q);
    std::printf("  tun dns packet %d bytes\n", static_cast<int>(dnsPkt.size()));
    SendPkt(testSide, dnsPkt);
    Pkt dns = ExpectPacket(testSide, 3000, 10, [](const Pkt& p) {
        return p.proto == 17 && p.dport == kClientUport && p.payload.size() > 20;
    }, "dns");
    if (!dns.valid || dns.payload.find("\x7f\x00\x00\x01") == std::string::npos) {
        std::printf("  tun dns hijack: no 127.0.0.1 answer\n");
        all = false;
    }

    (void)finSeq;
    udpRun.store(false);
    std::string logs = CoreGetLogs();
    std::printf("---- engine logs ----\n%s--------------------\n", logs.c_str());
    StopTun();
    closesocket(testSide);
    closesocket(tunSide);
    udpThr.detach();
    return all;
}

}  // namespace tunsim

int Run(const std::string& dir, const std::string& cfgName, bool selftest) {    std::fprintf(stderr, "[diag] dir=%s name=%s selftest=%d\n", dir.c_str(), cfgName.c_str(), selftest ? 1 : 0);
    std::string werr = CoreSetWorkingDir(dir.c_str());
    if (!werr.empty()) {
        std::printf("SetWorkingDir: %s\n", werr.c_str());
        return 2;
    }
    std::fprintf(stderr, "[diag] CoreStart...\n");
    std::string sErr = CoreStart(-1, cfgName.c_str());
    std::fprintf(stderr, "[diag] CoreStart returned %s\n", sErr.c_str());
    if (!sErr.empty()) {
        std::printf("Start: %s\n", sErr.c_str());
        return 2;
    }
    std::printf("version: %s\n", LumineGetVersion());
    std::printf("running: %d\n", LumineIsRunning());
    std::fprintf(stderr, "[diag] sleeping 500ms...\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    std::fprintf(stderr, "[diag] slept\n");

    if (!selftest) {
        std::printf("SOCKS5  -> 127.0.0.1:%d\nHTTP    -> 127.0.0.1:%d\nPress Enter to stop.\n", g_socks5Port, g_httpPort);
        std::getchar();
        CoreStop();
        return 0;
    }

    std::string lerr;
    int efd = CreateListener("127.0.0.1:" + std::to_string(g_echoPort), 16, lerr);
    if (efd < 0) {
        std::printf("echo listen: %s\n", lerr.c_str());
        CoreStop();
        return 2;
    }
    std::thread echoThr(EchoServer, efd);

    bool all = true;
    std::printf("[selftest] socks5 round trip (port %d -> echo %d)...\n", g_socks5Port, g_echoPort);
    all &= Socks5RoundTrip(g_socks5Port, g_echoPort);
    std::printf("[selftest] http  connect round trip (port %d -> echo %d)...\n", g_httpPort, g_echoPort);
    all &= HttpConnectRoundTrip(g_httpPort, g_echoPort);

    std::printf("[selftest] tun engine (tcp %d / udp / dns)...\n", g_echoPort);
    all &= tunsim::RunTunTests(g_echoPort);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    KillSocket(efd);
    echoThr.detach();

    std::printf("check config: %s\n", LumineCheckConfig());
    std::printf("[selftest] %s\n", all ? "PASS" : "FAIL");
    CoreStop();
    return all ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (!NetInitOnce()) {
        std::printf("socket init failed\n");
        return 2;
    }
    if (argc < 2) {
        std::printf("usage: main_cli <cfgDir> [cfgName] [--selftest]\n");
        return 2;
    }
    std::string dir = argv[1];
    std::string name = "config";
    bool selftest = false;
    for (int i = 2; i < argc; ++i) {
        if (std::string(argv[i]) == "--selftest") selftest = true;
        else name = argv[i];
    }
    return Run(dir, name, selftest);
}
#include "ltun.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include "lcore.h"
#include "lnet.h"
#include "lroute.h"
#include "ltunnel.h"
#include "ltypes.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace lcore {

extern std::atomic<bool> gStopFlag;

namespace {

constexpr int kMssV4 = 1460;
constexpr int kMssV6 = 1440;
constexpr uint32_t kAdvertisedWindow = 65535;
constexpr std::size_t kMaxUnacked = 256 * 1024;
constexpr int kRtoInitMs = 300;
constexpr int kRtoMaxMs = 8000;
constexpr int kMaxRetx = 12;
constexpr long long kFlowIdleMs = 10 * 60 * 1000;
constexpr long long kUdpIdleMs = 30 * 1000;
constexpr std::size_t kMaxUdpMappings = 512;
constexpr int kTimerTickMs = 100;

// 172.19.0.2 as bytes (DNS hijack target, mirrors Constants.DNS_ADDRESS).
const unsigned char kDnsV4[4] = {172, 19, 0, 2};

inline uint16_t Rd16(const unsigned char* p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

inline uint32_t Rd32(const unsigned char* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

inline void Wr16(unsigned char* p, uint16_t v) {
    p[0] = static_cast<unsigned char>(v >> 8);
    p[1] = static_cast<unsigned char>(v & 0xFF);
}

inline void Wr32(unsigned char* p, uint32_t v) {
    p[0] = static_cast<unsigned char>(v >> 24);
    p[1] = static_cast<unsigned char>((v >> 16) & 0xFF);
    p[2] = static_cast<unsigned char>((v >> 8) & 0xFF);
    p[3] = static_cast<unsigned char>(v & 0xFF);
}

// Descriptor slot shared by a flow/mapping and every thread that touches its
// socket. Close() takes the slot exclusively, so it can never run while a
// send/recv is in flight on the same descriptor; without this a descriptor
// closed by the reaper/stop path could be recycled by the OS and the next
// write would land on an unrelated socket.
class FdSlot {
  public:
    void Set(int fd) {
        std::unique_lock<std::shared_mutex> lk(mu_);
        if (fd_ >= 0 && fd_ != fd) KillSocket(fd_);
        fd_ = fd;
    }

    void Close() {
        std::unique_lock<std::shared_mutex> lk(mu_);
        if (fd_ >= 0) {
            KillSocket(fd_);
            fd_ = FdInvalid;
        }
    }

    int Get() const {
        std::shared_lock<std::shared_mutex> lk(mu_);
        return fd_;
    }

    template <typename Fn>
    void Use(Fn fn) const {
        std::shared_lock<std::shared_mutex> lk(mu_);
        if (fd_ >= 0) fn(fd_);
    }

    template <typename Fn>
    auto Call(Fn fn, decltype(fn(0)) fallback) const -> decltype(fn(0)) {
        std::shared_lock<std::shared_mutex> lk(mu_);
        if (fd_ < 0) return fallback;
        return fn(fd_);
    }

  private:
    mutable std::shared_mutex mu_;
    int fd_ = FdInvalid;
};

uint16_t Checksum(const unsigned char* data, std::size_t len) {
    uint32_t sum = 0;
    for (std::size_t i = 0; i + 1 < len; i += 2) {
        sum += Rd16(data + i);
    }
    if (len & 1) {
        sum += static_cast<uint16_t>(data[len - 1] << 8);
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return static_cast<uint16_t>(~sum);
}

// L4 checksum over pseudo-header + segment.
uint16_t L4Checksum(int family, const unsigned char* src, const unsigned char* dst,
                    const unsigned char* l4, std::size_t l4len, uint8_t nextHdr) {
    std::vector<unsigned char> buf;
    buf.reserve(40 + l4len + 1);
    if (family == 4) {
        buf.insert(buf.end(), src, src + 4);
        buf.insert(buf.end(), dst, dst + 4);
        buf.push_back(0);
        buf.push_back(nextHdr);
        Wr16(buf.data() + 10, static_cast<uint16_t>(l4len));
    } else {
        buf.insert(buf.end(), src, src + 16);
        buf.insert(buf.end(), dst, dst + 16);
        Wr32(buf.data() + 32, static_cast<uint32_t>(l4len));
        buf[39] = nextHdr;
    }
    buf.insert(buf.end(), l4, l4 + l4len);
    if (buf.size() & 1) buf.push_back(0);
    return Checksum(buf.data(), buf.size());
}

inline bool SeqBefore(uint32_t a, uint32_t b) {
    return static_cast<int32_t>(a - b) < 0;
}

inline bool SeqBeforeEq(uint32_t a, uint32_t b) {
    return static_cast<int32_t>(a - b) <= 0;
}

long long SteadyMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::string IpToString(int family, const unsigned char* a) {
    char buf[INET6_ADDRSTRLEN] = {0};
    inet_ntop(family == 4 ? AF_INET : AF_INET6, a, buf, sizeof(buf));
    return buf;
}

struct TcpFlags {
    static constexpr uint8_t FIN = 0x01;
    static constexpr uint8_t SYN = 0x02;
    static constexpr uint8_t RST = 0x04;
    static constexpr uint8_t PSH = 0x08;
    static constexpr uint8_t ACK = 0x10;
};

enum class FlowState { SynReceived, Established, ClientFin, ServerFin, Closed };

struct TcpSegment {
    uint32_t seq;
    std::vector<unsigned char> data;
    bool fin;
};

// ---------------------------------------------------------------------------
// Engine (forward decls so flows can call into it)
// ---------------------------------------------------------------------------

struct TcpFlow;
struct UdpMapping;

void TcpFlowHandleClientData(std::shared_ptr<TcpFlow> flow, std::vector<unsigned char> data);

class TunEngine {
  public:
    int tunFd = -1;
    std::atomic<bool> running{false};
    std::mutex writeMu;
    std::mutex mu;
    std::map<std::string, std::shared_ptr<struct TcpFlow>> flows;
    std::map<std::string, std::shared_ptr<UdpMapping>> udp;

    void WritePacket(const std::vector<unsigned char>& pkt);
    void HandleIp(const unsigned char* pkt, int len);
    void HandleTcp(const unsigned char* pkt, int len, int family,
                   const unsigned char* src, const unsigned char* dst,
                   int l4off, int l4len);
    void HandleUdp(const unsigned char* pkt, int len, int family,
                   const unsigned char* src, const unsigned char* dst,
                   int l4off, int l4len);
    void HandleIcmp(const unsigned char* pkt, int len, int family,
                    const unsigned char* src, const unsigned char* dst,
                    int l4off, int l4len);
    void ReapTick();

    bool BuildUdp(int family, const unsigned char* src, const unsigned char* dst,
                  uint16_t sport, uint16_t dport, const unsigned char* payload,
                  int payloadLen, std::vector<unsigned char>& out);

  private:
    void HandleDnsQuery(int family, const unsigned char* src, const unsigned char* dst,
                        uint16_t sport, const unsigned char* payload, int payloadLen);
};

TunEngine& Engine() {
    static TunEngine e;
    return e;
}

void TunEngine::WritePacket(const std::vector<unsigned char>& pkt) {
    std::lock_guard<std::mutex> lk(writeMu);
    if (tunFd < 0 || pkt.empty()) return;
    const char* p = reinterpret_cast<const char*>(pkt.data());
    std::size_t off = 0;
    while (off < pkt.size()) {
#ifdef _WIN32
        int n = send(SOCKET_CAST(tunFd), p + off, static_cast<int>(pkt.size() - off), 0);
#else
        ssize_t n = ::write(tunFd, p + off, pkt.size() - off);
#endif
        if (n <= 0) return;
        off += static_cast<std::size_t>(n);
    }
}

// ---------------------------------------------------------------------------
// UDP NAT
// ---------------------------------------------------------------------------

struct UdpMapping {
    int family = 4;
    std::string key;
    unsigned char srcIp[16] = {0};
    uint16_t srcPort = 0;
    unsigned char dstIp[16] = {0};
    uint16_t dstPort = 0;
    FdSlot sock;
    std::atomic<long long> lastActive{0};

    void ReaderLoop();
    void Close() { sock.Close(); }
};

bool TunEngine::BuildUdp(int family, const unsigned char* src, const unsigned char* dst,
                         uint16_t sport, uint16_t dport, const unsigned char* payload,
                         int payloadLen, std::vector<unsigned char>& out) {
    int l4len = 8 + payloadLen;
    int hdrLen = (family == 4) ? 20 : 40;
    out.assign(hdrLen + l4len, 0);
    std::vector<unsigned char> l4(l4len);
    Wr16(l4.data(), sport);
    Wr16(l4.data() + 2, dport);
    Wr16(l4.data() + 4, static_cast<uint16_t>(l4len));
    l4[6] = 0;
    l4[7] = 0;
    std::memcpy(l4.data() + 8, payload, payloadLen);
    uint16_t ck = L4Checksum(family, src, dst, l4.data(), l4len, 17);
    l4[6] = static_cast<unsigned char>(ck >> 8);
    l4[7] = static_cast<unsigned char>(ck & 0xFF);

    if (family == 4) {
        out[0] = 0x45;
        out[1] = 0;
        Wr16(&out[2], static_cast<uint16_t>(hdrLen + l4len));
        Wr16(&out[4], 0);
        out[6] = 0x40;  // DF
        out[7] = 0;
        out[8] = 64;
        out[9] = 17;
        std::memcpy(&out[12], src, 4);
        std::memcpy(&out[16], dst, 4);
        Wr16(&out[10], Checksum(out.data(), 20));
        std::memcpy(out.data() + 20, l4.data(), l4len);
    } else {
        out[0] = 0x60;
        Wr16(&out[4], static_cast<uint16_t>(l4len));
        out[6] = 17;
        out[7] = 64;
        std::memcpy(&out[8], src, 16);
        std::memcpy(&out[24], dst, 16);
        std::memcpy(out.data() + 40, l4.data(), l4len);
    }
    return true;
}

void TunEngine::HandleUdp(const unsigned char* pkt, int len, int family,
                          const unsigned char* src, const unsigned char* dst,
                          int l4off, int l4len) {
    if (l4len < 8) return;
    uint16_t sport = Rd16(pkt + l4off);
    uint16_t dport = Rd16(pkt + l4off + 2);
    int ulen = Rd16(pkt + l4off + 4);
    if (ulen < 8 || l4off + ulen > len) ulen = l4len;
    int payloadLen = ulen - 8;
    const unsigned char* payload = pkt + l4off + 8;

    bool isDns = (dport == 53) &&
                 ((family == 4 && std::memcmp(dst, kDnsV4, 4) == 0) ||
                  (family == 6 && dst[0] == 0xfd));
    if (isDns) {
        HandleDnsQuery(family, src, dst, sport, payload, payloadLen);
        return;
    }

    std::string key = IpToString(family, src) + "|" + std::to_string(sport) + "|" +
                      IpToString(family, dst) + "|" + std::to_string(dport);
    std::shared_ptr<UdpMapping> m;
    {
        std::lock_guard<std::mutex> lk(mu);
        auto it = udp.find(key);
        // A mapping whose socket has already been closed by the reaper is
        // stale: its reader owns the erase, so replace the entry instead of
        // resurrecting a dead descriptor.
        if (it != udp.end() && it->second->sock.Get() >= 0) {
            m = it->second;
        } else if (it == udp.end() && udp.size() >= kMaxUdpMappings) {
            Logger::Get().Log(LogLevel::Warn, "TUN udp mapping table full, drop");
            return;
        }
    }
    if (!m) {
        m = std::make_shared<UdpMapping>();
        m->family = family;
        m->key = key;
        std::memcpy(m->srcIp, src, family == 4 ? 4 : 16);
        m->srcPort = sport;
        std::memcpy(m->dstIp, dst, family == 4 ? 4 : 16);
        m->dstPort = dport;
        int ufd = static_cast<int>(socket(family == 4 ? AF_INET : AF_INET6, SOCK_DGRAM, 0));
        if (ufd < 0) return;
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        setsockopt(ufd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
        m->sock.Set(ufd);
        m->lastActive.store(SteadyMs());
        std::lock_guard<std::mutex> lk(mu);
        udp[key] = m;
        Stats().udpConns++;
        try {
            std::thread([m]() { m->ReaderLoop(); }).detach();
        } catch (...) {
            Logger::Get().Log(LogLevel::Error, "TUN cannot spawn udp reader, mapping dropped");
            udp.erase(key);
            Stats().udpConns--;
            m->Close();
            return;
        }
    }
    m->lastActive.store(SteadyMs());
    struct sockaddr_storage ss;
    socklen_t slen = 0;
    if (MakeSockAddr(IpToString(family, dst), dport, ss, slen) != 0) return;
    int sent = m->sock.Call(
        [&](int ufd) {
            return static_cast<int>(sendto(SOCKET_CAST(ufd), reinterpret_cast<const char*>(payload),
                                           payloadLen, 0, reinterpret_cast<struct sockaddr*>(&ss), slen));
        },
        -1);
    if (sent > 0) {
        Stats().up.fetch_add(payloadLen);
    }
}

void UdpMapping::ReaderLoop() {
    unsigned char buf[65535];
    for (;;) {
        if (gStopFlag.load() || sock.Get() < 0) break;
        int n = sock.Call(
            [&](int mfd) {
                return static_cast<int>(recv(SOCKET_CAST(mfd), reinterpret_cast<char*>(buf), sizeof(buf), 0));
            },
            0);
        if (n <= 0) {
            if (n < 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            }
            break;
        }
        long long now = SteadyMs();
        if (now - lastActive.load() > kUdpIdleMs) break;
        lastActive.store(now);
        std::vector<unsigned char> pkt;
        TunEngine& e = Engine();
        if (e.BuildUdp(family, dstIp, srcIp, dstPort, srcPort, buf, n, pkt)) {
            e.WritePacket(pkt);
            Stats().down.fetch_add(n);
        }
    }
    {
        TunEngine& e = Engine();
        std::lock_guard<std::mutex> lk(e.mu);
        auto it = e.udp.find(key);
        // Only the mapping that is still registered may erase the slot: a
        // replacement created after the reaper closed this one owns it now.
        if (it != e.udp.end() && it->second.get() == this) {
            e.udp.erase(it);
            Stats().udpConns--;
        }
    }
    Close();
}

// ---------------------------------------------------------------------------
// DNS hijack (172.19.0.2:53)
// ---------------------------------------------------------------------------

void TunEngine::HandleDnsQuery(int family, const unsigned char* src, const unsigned char* dst,
                               uint16_t sport, const unsigned char* payload, int payloadLen) {
    Logger& lg = Logger::Get();
    if (payloadLen < 12) return;
    uint16_t id = Rd16(payload);
    uint16_t qd = Rd16(payload + 4);
    if (qd != 1) return;

    // Parse the first question.
    int off = 12;
    std::string name;
    while (off < payloadLen) {
        int lab = payload[off];
        if (lab == 0) {
            off++;
            break;
        }
        if ((lab & 0xC0) != 0 || off + 1 + lab > payloadLen) return;
        if (!name.empty()) name.push_back('.');
        name.append(reinterpret_cast<const char*>(payload) + off + 1, static_cast<std::size_t>(lab));
        off += 1 + lab;
    }
    if (off + 4 > payloadLen) return;
    uint16_t qtype = Rd16(payload + off);
    off += 4;
    int questionEnd = off;

    uint16_t an = 0;
    std::vector<unsigned char> rdata;
    uint16_t rtype = qtype;
    if (qtype == 1 || qtype == 28) {
        DNSMode pref = (qtype == 28) ? DNSMode::PreferIPv6 : DNSMode::PreferIPv4;
        std::string ip;
        bool cached = false;
        if (ResolveHost(name, pref, 0, ip, cached)) {
            unsigned char bin[16] = {0};
            if (inet_pton(family == 4 ? AF_INET : AF_INET6, ip.c_str(), bin) == 1) {
                an = 1;
                int rl = (qtype == 1) ? 4 : 16;
                rdata.assign(bin, bin + rl);
            } else if (family == 4 && qtype == 28) {
                // AAAA over v4 resolver often fails; fall back to A-in-AAAA is
                // invalid, so report an empty answer instead.
                lg.Log(LogLevel::Info, "TUN dns " + name + " no AAAA (v4-only resolver)");
            }
        }
    }
    if (an == 0 && (qtype == 1 || qtype == 28)) {
        lg.Log(LogLevel::Info, "TUN dns " + name + " qtype=" + std::to_string(qtype) + " nxdomain/failed");
    }

    std::vector<unsigned char> resp;
    resp.reserve(512);
    auto push16 = [&resp](uint16_t v) {
        resp.push_back(static_cast<unsigned char>(v >> 8));
        resp.push_back(static_cast<unsigned char>(v & 0xFF));
    };
    auto push32 = [&resp](uint32_t v) {
        resp.push_back(static_cast<unsigned char>(v >> 24));
        resp.push_back(static_cast<unsigned char>((v >> 16) & 0xFF));
        resp.push_back(static_cast<unsigned char>((v >> 8) & 0xFF));
        resp.push_back(static_cast<unsigned char>(v & 0xFF));
    };
    push16(id);
    push16(0x8180);  // QR=1, RD=1, RA=1
    push16(1);       // qd
    push16(an);      // an
    push16(0);
    push16(0);
    resp.insert(resp.end(), payload + 12, payload + questionEnd);
    if (an == 1) {
        push16(0xC00C);  // name pointer to question
        push16(rtype);
        push16(1);       // IN
        push32(300);     // ttl
        push16(static_cast<uint16_t>(rdata.size()));
        resp.insert(resp.end(), rdata.begin(), rdata.end());
    }

    std::vector<unsigned char> pkt;
    if (BuildUdp(family, dst, src, 53, sport, resp.data(), static_cast<int>(resp.size()), pkt)) {
        WritePacket(pkt);
    }
}

// ---------------------------------------------------------------------------
// ICMP echo
// ---------------------------------------------------------------------------

void TunEngine::HandleIcmp(const unsigned char* pkt, int len, int family,
                           const unsigned char* src, const unsigned char* dst,
                           int l4off, int l4len) {
    if (family == 4) {
        if (l4len < 8 || pkt[l4off] != 8) return;  // echo request only
        std::vector<unsigned char> out(pkt, pkt + len);
        std::memcpy(&out[12], dst, 4);
        std::memcpy(&out[16], src, 4);
        out[l4off] = 0;  // echo reply
        out[l4off + 2] = 0;
        out[l4off + 3] = 0;
        uint16_t ck = Checksum(&out[l4off], static_cast<std::size_t>(len - l4off));
        out[l4off + 2] = static_cast<unsigned char>(ck >> 8);
        out[l4off + 3] = static_cast<unsigned char>(ck & 0xFF);
        Wr16(&out[10], 0);
        Wr16(&out[10], Checksum(out.data(), 20));
        WritePacket(out);
        return;
    }
    if (l4len < 8 || pkt[l4off] != 128) return;  // ICMPv6 echo request
    std::vector<unsigned char> out(pkt, pkt + len);
    std::memcpy(&out[8], dst, 16);
    std::memcpy(&out[24], src, 16);
    out[l4off] = 129;
    out[l4off + 2] = 0;
    out[l4off + 3] = 0;
    uint16_t ck = L4Checksum(6, dst, src, &out[l4off], static_cast<std::size_t>(l4len), 58);
    out[l4off + 2] = static_cast<unsigned char>(ck >> 8);
    out[l4off + 3] = static_cast<unsigned char>(ck & 0xFF);
    WritePacket(out);
}

// ---------------------------------------------------------------------------
// Virtual TCP stack
// ---------------------------------------------------------------------------

struct TcpFlow : public std::enable_shared_from_this<TcpFlow> {
    int family = 4;
    unsigned char src[16] = {0};  // tun-side client
    unsigned char dst[16] = {0};
    uint16_t sport = 0;
    uint16_t dport = 0;
    std::string tuple;
    std::string dstIpStr;
    int mss = kMssV4;

    std::mutex fmu;
    std::atomic<FlowState> state{FlowState::SynReceived};
    uint32_t clIsn = 0;
    uint32_t clNext = 0;    // next expected seq from client
    uint32_t iss = 0;       // our ISN
    uint32_t nxt = 0;       // our next seq to send (iss + sent unacked)
    uint32_t clAck = 0;
    std::deque<TcpSegment> sendQ;
    int retxCount = 0;
    std::atomic<long long> rto{kRtoInitMs};
    std::atomic<long long> lastSendOrAck{0};
    std::atomic<long long> lastActive{0};
    std::atomic<bool> reaped{false};
    bool finQueued = false;
    bool finAcked = false;
    bool clientFinSeen = false;
    uint32_t clientFinSeq = 0;

    FdSlot sock;
    std::atomic<bool> dialing{false};
    std::atomic<bool> dialed{false};
    std::atomic<bool> readerStarted{false};
    std::string upBuf;  // client->server bytes buffered before dial completes
    bool sniffDone = false;
    Mode applied = Mode::Unset;
    std::string routeHost;
    HuiPolicy policy;

    long long now = 0;

    std::string Key() const { return tuple; }
    std::string Label() const {
        return "TUN " + IpToString(family, src) + ":" + std::to_string(sport) + " -> " +
               dstIpStr + ":" + std::to_string(dport);
    }

    // ---- packet construction ----
    std::vector<unsigned char> BuildSegment(uint8_t flags, uint32_t seq, uint32_t ack,
                                            const unsigned char* payload, int payloadLen,
                                            bool withMss) {
        std::vector<unsigned char> l4;
        int hdrLen = 20 + (withMss ? 4 : 0);
        l4.assign(hdrLen + payloadLen, 0);
        Wr16(l4.data(), sport);
        Wr16(l4.data() + 2, dport);
        Wr32(l4.data() + 4, seq);
        Wr32(l4.data() + 8, ack);
        l4[12] = static_cast<unsigned char>((hdrLen / 4) << 4);
        l4[13] = flags;
        Wr16(l4.data() + 14, static_cast<uint16_t>(kAdvertisedWindow));
        if (withMss) {
            l4[20] = 2;   // MSS kind
            l4[21] = 4;   // len
            Wr16(l4.data() + 22, static_cast<uint16_t>(mss));
        }
        if (payloadLen > 0) std::memcpy(l4.data() + hdrLen, payload, payloadLen);
        uint16_t ck = L4Checksum(family, dst, src, l4.data(), l4.size(), 6);
        l4[16] = static_cast<unsigned char>(ck >> 8);
        l4[17] = static_cast<unsigned char>(ck & 0xFF);

        int ipHdr = (family == 4) ? 20 : 40;
        std::vector<unsigned char> out(ipHdr + l4.size(), 0);
        if (family == 4) {
            out[0] = 0x45;
            out[1] = 0;
            Wr16(&out[2], static_cast<uint16_t>(out.size()));
            Wr16(&out[4], 0);
            out[6] = 0x40;
            out[7] = 0;
            out[8] = 64;
            out[9] = 6;
            std::memcpy(&out[12], dst, 4);
            std::memcpy(&out[16], src, 4);
            Wr16(&out[10], Checksum(out.data(), 20));
        } else {
            out[0] = 0x60;
            Wr16(&out[4], static_cast<uint16_t>(l4.size()));
            out[6] = 6;
            out[7] = 64;
            std::memcpy(&out[8], dst, 16);
            std::memcpy(&out[24], src, 16);
        }
        std::memcpy(out.data() + ipHdr, l4.data(), l4.size());
        return out;
    }

    void SendNow(uint8_t flags, uint32_t seq, uint32_t ack, const unsigned char* payload,
                 int payloadLen, bool withMss = false) {
        TunEngine& e = Engine();
        e.WritePacket(BuildSegment(flags, seq, ack, payload, payloadLen, withMss));
    }

    void SendRst() {
        SendNow(TcpFlags::RST | TcpFlags::ACK, nxt, clNext, nullptr, 0);
    }

    // ---- transmit / ack bookkeeping (call with fmu held) ----
    void TransmitLocked(long long nowMs) {
        for (const auto& s : sendQ) {
            SendNow(s.fin ? (TcpFlags::ACK | TcpFlags::FIN | TcpFlags::PSH) : (TcpFlags::ACK | TcpFlags::PSH),
                    s.seq, clNext, s.data.data(), static_cast<int>(s.data.size()));
        }
        lastSendOrAck.store(nowMs);
    }

    void EnqueueDown(const unsigned char* data, int len, bool fin) {
        if (len <= 0 && !fin) return;
        TcpSegment s;
        s.seq = nxt;
        s.fin = fin;
        s.data.assign(data, data + std::max(0, len));
        nxt += static_cast<uint32_t>(len) + (fin ? 1u : 0u);
        sendQ.push_back(std::move(s));
        uint8_t flags = fin ? (TcpFlags::ACK | TcpFlags::FIN | TcpFlags::PSH)
                            : (TcpFlags::ACK | TcpFlags::PSH);
        const TcpSegment& seg = sendQ.back();
        SendNow(flags, seg.seq, clNext, seg.data.data(), static_cast<int>(seg.data.size()));
        lastSendOrAck.store(now);
    }

    void OnAckLocked(uint32_t ack) {
        clAck = ack;
        while (!sendQ.empty()) {
            TcpSegment& s = sendQ.front();
            uint32_t end = s.seq + static_cast<uint32_t>(s.data.size()) + (s.fin ? 1u : 0u);
            if (SeqBefore(ack, end)) {
                if (SeqBefore(s.seq, ack)) {
                    std::size_t trim = ack - s.seq;
                    if (trim < s.data.size()) {
                        s.data.erase(s.data.begin(), s.data.begin() + static_cast<long>(trim));
                    } else {
                        s.data.clear();
                    }
                    s.seq = ack;
                }
                break;
            }
            if (s.fin && ack == end) {
                finAcked = true;
            }
            sendQ.pop_front();
            retxCount = 0;
            rto.store(kRtoInitMs);
            lastSendOrAck.store(now);
        }
        if (sendQ.empty() && finQueued && finAcked && clientFinSeen && state != FlowState::Closed) {
            state = FlowState::Closed;
        }
    }

    // ---- lifecycle ----
    // Idempotent: the first caller wins, later callers return immediately. The
    // flow registers itself in the engine map, so teardown must always erase it
    // and drop the connection counter no matter which state it reached.
    void Teardown(bool sendRstToClient) {
        if (reaped.exchange(true)) return;
        uint32_t rstSeq = 0;
        uint32_t rstAck = 0;
        {
            std::lock_guard<std::mutex> lk(fmu);
            rstSeq = nxt;
            rstAck = clNext;
            state = FlowState::Closed;
        }
        if (sendRstToClient) {
            SendNow(TcpFlags::RST | TcpFlags::ACK, rstSeq, rstAck, nullptr, 0);
        }
        sock.Close();
        {
            TunEngine& e = Engine();
            std::lock_guard<std::mutex> lk(e.mu);
            auto it = e.flows.find(Key());
            if (it != e.flows.end() && it->second.get() == this) {
                e.flows.erase(it);
                Stats().DecTcp();
            }
        }
    }

    void RealToTunLoop();

    // Worker: route + dial + apply policy to buffered client bytes.
    void DialWorker();
};

void TunEngine::HandleTcp(const unsigned char* pkt, int len, int family,
                          const unsigned char* src, const unsigned char* dst,
                          int l4off, int l4len) {
    (void)len;
    if (l4len < 20) return;
    const unsigned char* tcp = pkt + l4off;
    uint16_t sport = Rd16(tcp);
    uint16_t dport = Rd16(tcp + 2);
    uint32_t seq = Rd32(tcp + 4);
    uint32_t ack = Rd32(tcp + 8);
    int dataOff = (tcp[12] >> 4) * 4;
    if (dataOff < 20 || dataOff > l4len) return;
    uint8_t flags = tcp[13];
    int payloadLen = l4len - dataOff;
    const unsigned char* payload = tcp + dataOff;

    std::string key = IpToString(family, src) + "|" + std::to_string(sport) + "|" +
                      IpToString(family, dst) + "|" + std::to_string(dport);

    std::shared_ptr<TcpFlow> flow;
    {
        std::lock_guard<std::mutex> lk(mu);
        auto it = flows.find(key);
        if (it != flows.end()) flow = it->second;
    }

    if (!flow) {
        if (!(flags & TcpFlags::SYN) || (flags & TcpFlags::ACK)) return;
        flow = std::make_shared<TcpFlow>();
        flow->family = family;
        std::memcpy(flow->src, src, family == 4 ? 4 : 16);
        std::memcpy(flow->dst, dst, family == 4 ? 4 : 16);
        flow->sport = sport;
        flow->dport = dport;
        flow->tuple = key;
        flow->dstIpStr = IpToString(family, dst);
        flow->mss = (family == 4) ? kMssV4 : kMssV6;
        // Parse MSS option from SYN to stay below the client's advertised MSS.
        if (dataOff > 20) {
            int o = 20;
            while (o + 1 < dataOff) {
                int kind = tcp[o];
                if (kind == 0) break;
                int olen = (kind == 1) ? 1 : tcp[o + 1];
                if (olen <= 0 || o + olen > dataOff) break;
                if (kind == 2 && olen == 4) {
                    int peerMss = Rd16(tcp + o + 2);
                    if (peerMss > 0 && peerMss < flow->mss) flow->mss = peerMss;
                }
                o += olen;
            }
        }
        flow->clIsn = seq;
        flow->clNext = seq + 1;
        uint32_t isn = static_cast<uint32_t>(SteadyMs()) & 0xFFFFFFFFu;
        isn ^= static_cast<uint32_t>(reinterpret_cast<uintptr_t>(flow.get()));
        flow->iss = isn;
        flow->nxt = isn + 1;
        flow->clAck = seq;
        flow->now = SteadyMs();
        flow->lastActive.store(flow->now);
        {
            std::lock_guard<std::mutex> lk(mu);
            flows[key] = flow;
        }
        Stats().AddTcp(1);
        flow->SendNow(TcpFlags::SYN | TcpFlags::ACK, flow->iss, flow->clNext, nullptr, 0, true);
        Logger::Get().Log(LogLevel::Info, flow->Label() + " syn received");
        return;
    }

    {
        std::unique_lock<std::mutex> lk(flow->fmu);
        flow->now = SteadyMs();
        flow->lastActive.store(flow->now);
        if (flags & TcpFlags::RST) {
            lk.unlock();
            flow->Teardown(false);
            Logger::Get().Log(LogLevel::Info, flow->Label() + " client reset");
            return;
        }
        if (flags & TcpFlags::ACK) {
            flow->OnAckLocked(ack);
        }
        bool inOrder = (seq == flow->clNext);
        if (payloadLen > 0) {
            if (inOrder && flow->state != FlowState::Closed) {
                flow->clNext += static_cast<uint32_t>(payloadLen);
                std::vector<unsigned char> data(payload, payload + payloadLen);
                lk.unlock();
                TcpFlowHandleClientData(flow, std::move(data));
                return;
            }
            // Out-of-order or closed: duplicate ack so the sender retransmits.
            flow->SendNow(TcpFlags::ACK, flow->nxt, flow->clNext, nullptr, 0);
            return;
        }
        if (flags & TcpFlags::FIN) {
            if (inOrder) flow->clNext += 1;
            flow->clientFinSeen = true;
            flow->clientFinSeq = seq + static_cast<uint32_t>(payloadLen);
            flow->SendNow(TcpFlags::ACK, flow->nxt, flow->clNext, nullptr, 0);
            if (flow->dialed.load()) {
                flow->sock.Use([](int sfd) { LShutdown(sfd, 1); });
            }
            if (flow->state == FlowState::Established) flow->state = FlowState::ClientFin;
            if (flow->sendQ.empty() && flow->finQueued && flow->finAcked) {
                flow->state = FlowState::Closed;
            }
        }
    }
}

}  // namespace

}  // namespace lcore

// Reopen the namespace to define members that reference each other.
namespace lcore {
namespace {

void TunEngineTimerLoop() {
    TunEngine& e = Engine();
    while (!gStopFlag.load() && e.running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kTimerTickMs));
        if (gStopFlag.load() || !e.running.load()) break;
        e.ReapTick();
    }
}

void TunEngineReadLoop() {
    TunEngine& e = Engine();
    unsigned char buf[65535];
    while (!gStopFlag.load() && e.running.load()) {
#ifdef _WIN32
        int n = recv(SOCKET_CAST(e.tunFd), reinterpret_cast<char*>(buf), sizeof(buf), 0);
#else
        int n = static_cast<int>(read(e.tunFd, buf, sizeof(buf)));
#endif
        if (n <= 0) {
            if (n < 0 && !e.running.load()) break;
            if (n < 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(40));
                continue;
            }
            continue;
        }
        if (n < 20) continue;
        e.HandleIp(buf, n);
    }
}

void TunEngine::HandleIp(const unsigned char* pkt, int len) {
    int family = 0;
    const unsigned char* src;
    const unsigned char* dst;
    uint8_t proto;
    int l4off;
    int l4len;
    if ((pkt[0] >> 4) == 4) {
        if (len < 20) return;
        int ihl = (pkt[0] & 0x0F) * 4;
        if (ihl < 20 || ihl > len) return;
        uint16_t total = Rd16(pkt + 2);
        if (total >= 20 && total <= len) len = total;
        uint16_t frag = Rd16(pkt + 6);
        if ((frag & 0x1FFF) != 0) return;  // non-first fragment: drop
        family = 4;
        src = pkt + 12;
        dst = pkt + 16;
        proto = pkt[9];
        l4off = ihl;
        l4len = len - ihl;
    } else if ((pkt[0] >> 4) == 6) {
        if (len < 40) return;
        family = 6;
        src = pkt + 8;
        dst = pkt + 24;
        proto = pkt[6];
        if (proto != 6 && proto != 17 && proto != 58 && proto != 0) return;
        l4off = 40;
        l4len = len - 40;
    } else {
        return;
    }

    switch (proto) {
        case 6:
            HandleTcp(pkt, len, family, src, dst, l4off, l4len);
            break;
        case 17:
            HandleUdp(pkt, len, family, src, dst, l4off, l4len);
            break;
        case 58:
        case 1:
            HandleIcmp(pkt, len, family, src, dst, l4off, l4len);
            break;
        default:
            break;
    }
    (void)l4len;
}

void TunEngine::ReapTick() {
    long long now = SteadyMs();
    std::vector<std::shared_ptr<TcpFlow>> retx;
    std::vector<std::shared_ptr<TcpFlow>> expired;
    {
        std::lock_guard<std::mutex> lk(mu);
        for (auto& kv : flows) {
            if (now - kv.second->lastActive.load() > kFlowIdleMs) {
                expired.push_back(kv.second);
            } else if (!kv.second->reaped.load()) {
                bool pending = false;
                long long last = 0;
                long long rto = 0;
                {
                    std::lock_guard<std::mutex> flk(kv.second->fmu);
                    pending = !kv.second->sendQ.empty();
                }
                last = kv.second->lastSendOrAck.load();
                rto = kv.second->rto.load();
                if (pending && now - last >= rto) {
                    retx.push_back(kv.second);
                }
            }
        }
    }
    for (auto& f : retx) {
        std::unique_lock<std::mutex> lk(f->fmu);
        if (f->state == FlowState::Closed || f->reaped.load()) continue;
        if (f->sendQ.empty()) continue;
        f->retxCount++;
        if (f->retxCount > kMaxRetx) {
            Logger::Get().Log(LogLevel::Warn, f->Label() + " retransmit limit, reset");
            lk.unlock();
            f->Teardown(true);
            continue;
        }
        f->rto.store(std::min<long long>(f->rto.load() * 2, kRtoMaxMs));
        f->TransmitLocked(now);
    }
    for (auto& f : expired) {
        Logger::Get().Log(LogLevel::Info, f->Label() + " idle timeout");
        f->Teardown(true);
    }
    std::vector<std::shared_ptr<UdpMapping>> deadUdp;
    {
        std::lock_guard<std::mutex> lk(mu);
        for (auto& kv : udp) {
            if (now - kv.second->lastActive.load() > kUdpIdleMs) deadUdp.push_back(kv.second);
        }
    }
    for (auto& m : deadUdp) {
        // Close through the slot so the reader thread cannot close the same
        // descriptor a second time after the OS recycled the number.
        m->Close();
    }
}

// ---- client data path ------------------------------------------------------

void TcpFlowHandleClientData(std::shared_ptr<TcpFlow> flow, std::vector<unsigned char> data) {
    if (flow->reaped.load()) {
        return;
    }
    bool direct = false;
    {
        // The dialed flag and the pre-dial buffer are manipulated under fmu by
        // DialWorker as well, so sampling both here cannot lose bytes into a
        // buffer that was already drained.
        std::lock_guard<std::mutex> lk(flow->fmu);
        if (flow->reaped.load() || flow->state == FlowState::Closed) {
            return;
        }
        if (flow->dialed.load()) {
            direct = true;
        } else {
            flow->upBuf.append(reinterpret_cast<const char*>(data.data()), data.size());
        }
    }
    if (direct) {
        bool ok = flow->sock.Call(
            [&](int fd) {
                return WriteAll(fd, reinterpret_cast<const char*>(data.data()), data.size());
            },
            false);
        if (!ok) {
            flow->Teardown(true);
            return;
        }
        Stats().up.fetch_add(data.size());
        return;
    }
    bool expected = false;
    if (!flow->dialing.compare_exchange_strong(expected, true)) {
        return;
    }
    try {
        std::thread([flow]() { flow->DialWorker(); }).detach();
    } catch (...) {
        Logger::Get().Log(LogLevel::Error, flow->Label() + " cannot spawn dial worker");
        flow->dialing.store(false);
        flow->Teardown(true);
    }
}

void TcpFlow::RealToTunLoop() {
    std::shared_ptr<TcpFlow> self = shared_from_this();
    char buf[16384];
    for (;;) {
        if (gStopFlag.load() || state == FlowState::Closed) break;
        std::size_t pending = 0;
        {
            std::lock_guard<std::mutex> lk(fmu);
            for (const auto& s : sendQ) pending += s.data.size();
        }
        if (pending > kMaxUnacked) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        int n = sock.Call(
            [&](int fd) {
                return static_cast<int>(recv(SOCKET_CAST(fd), buf, sizeof(buf), 0));
            },
            0);
        if (n > 0) {
            std::lock_guard<std::mutex> lk(fmu);
            if (state == FlowState::Closed || reaped.load()) break;
            Stats().down.fetch_add(n);
            std::size_t off = 0;
            while (off < static_cast<std::size_t>(n)) {
                std::size_t chunk = std::min<std::size_t>(static_cast<std::size_t>(mss),
                                                          static_cast<std::size_t>(n) - off);
                EnqueueDown(reinterpret_cast<const unsigned char*>(buf) + off,
                            static_cast<int>(chunk), false);
                off += chunk;
            }
            continue;
        }
        if (n == 0) {
            std::lock_guard<std::mutex> lk(fmu);
            if (!finQueued && state != FlowState::Closed) {
                finQueued = true;
                EnqueueDown(nullptr, 0, true);
            }
            break;
        }
        int errCode = TranslateErrno();
#ifdef _WIN32
        if (errCode == WSAETIMEDOUT || errCode == WSAEWOULDBLOCK) continue;
#else
        if (errCode == EAGAIN || errCode == EWOULDBLOCK) continue;
#endif
        {
            std::lock_guard<std::mutex> lk(fmu);
            if (!finQueued && state != FlowState::Closed) {
                finQueued = true;
                EnqueueDown(nullptr, 0, true);
            }
            break;
        }
    }
}

void TcpFlow::DialWorker() {
    Logger& lg = Logger::Get();

    std::shared_ptr<const Config> cfg = GetCoreConfig();
    if (!cfg) {
        lg.Log(LogLevel::Error, Label() + " no config loaded");
        Teardown(true);
        return;
    }
    RouteResult r = Route(*cfg, dstIpStr, true, false);
    if (r.blocked) {
        lg.Log(LogLevel::Info, Label() + " blocked by policy");
        Stats().blocked++;
        Teardown(true);
        return;
    }
    if (r.failed) {
        lg.Log(LogLevel::Error, Label() + " route failed");
        Teardown(true);
        return;
    }
    policy = r.policy;
    routeHost = r.dstHost;

    long long to = policy.connectTimeoutMs > 0 ? policy.connectTimeoutMs : 10000;
    std::string err;
    int fd = DialIpPort(routeHost, dport, to, err);
    if (fd < 0) {
        lg.Log(LogLevel::Error, Label() + " dial " + routeHost + " failed: " + err);
        Teardown(true);
        return;
    }
    if (reaped.load()) {
        KillSocket(fd);
        return;
    }
    sock.Set(fd);
    dialed.store(true);

    std::string first;
    {
        std::lock_guard<std::mutex> lk(fmu);
        first.swap(upBuf);
    }

    if (!first.empty()) {
        bool isTLS = first.size() >= 5 &&
                     static_cast<unsigned char>(first[0]) == 0x16 &&
                     static_cast<unsigned char>(first[1]) == 0x03;
        Mode mode = (policy.mode == Mode::Unset) ? Mode::TLSRF : policy.mode;
        if (isTLS) {
            std::size_t recLen = 5 + (static_cast<std::size_t>(static_cast<unsigned char>(first[3]) << 8) |
                                      static_cast<unsigned char>(first[4]));
            if (first.size() >= recLen) {
                ParsedClientHello ph = ParseClientHello(first.substr(0, recLen));
                if (ph.ok && mode == Mode::TLSRF && ph.sniStart > 0 && ph.sniLen > 0) {
                    std::string record = first.substr(0, recLen);
                    std::string ferr;
                    bool sent = sock.Call(
                        [&](int realFd) { return SendRecords(realFd, record, ph.sniStart, ph.sniLen, policy, ferr); },
                        false);
                    if (sent) {
                        std::string tail = first.substr(recLen);
                        bool tailOk = tail.empty() || sock.Call(
                            [&](int realFd) {
                                return WriteAll(realFd, reinterpret_cast<const char*>(tail.data()), tail.size());
                            },
                            false);
                        if (!tailOk) {
                            Teardown(true);
                            return;
                        }
                        sniffDone = true;
                        lg.Log(LogLevel::Info, Label() + " tls-rf via " + routeHost +
                                               " sni=" + first.substr(static_cast<std::size_t>(ph.sniStart),
                                                                      static_cast<std::size_t>(ph.sniLen)));
                    } else {
                        lg.Log(LogLevel::Error, Label() + " tls fragment failed: " + ferr);
                        Teardown(true);
                        return;
                    }
                } else {
                    bool written = sock.Call(
                        [&](int realFd) {
                            return WriteAll(realFd, reinterpret_cast<const char*>(first.data()), first.size());
                        },
                        false);
                    if (!written) {
                        Teardown(true);
                        return;
                    }
                    sniffDone = true;
                }
            } else {
                lg.Log(LogLevel::Warn, Label() + " partial TLS record in first segment, forward raw");
                bool written = sock.Call(
                    [&](int realFd) {
                        return WriteAll(realFd, reinterpret_cast<const char*>(first.data()), first.size());
                    },
                    false);
                if (!written) {
                    Teardown(true);
                    return;
                }
                sniffDone = true;
            }
        } else {
            bool written = sock.Call(
                [&](int realFd) {
                    return WriteAll(realFd, reinterpret_cast<const char*>(first.data()), first.size());
                },
                false);
            if (!written) {
                Teardown(true);
                return;
            }
            sniffDone = true;
        }
        Stats().up.fetch_add(first.size());
    }

    SetSockRcvTimeout(fd, 1500);
    if (reaped.load()) {
        return;
    }
    if (!readerStarted.exchange(true)) {
        try {
            std::thread([self = this->shared_from_this()]() { self->RealToTunLoop(); }).detach();
        } catch (...) {
            Logger::Get().Log(LogLevel::Error, Label() + " cannot spawn reader thread");
            Teardown(true);
        }
    }
}

// ---------------------------------------------------------------------------
// Start / stop
// ---------------------------------------------------------------------------

std::mutex g_tunStateMu;
std::thread g_tunReader;
std::thread g_tunTimer;
int g_tunFd = FdInvalid;

}  // namespace

std::string StartTun(int fd) {
    std::lock_guard<std::mutex> lk(g_tunStateMu);
    if (Engine().running.load()) {
        return "";
    }
    if (fd < 0) {
        return "tun fd invalid";
    }
    TunEngine& e = Engine();
    e.tunFd = fd;
    g_tunFd = fd;
    gStopFlag.store(false);
    e.running.store(true);
    try {
        g_tunReader = std::thread(TunEngineReadLoop);
        g_tunTimer = std::thread(TunEngineTimerLoop);
    } catch (...) {
        e.running.store(false);
        gStopFlag.store(true);
        e.tunFd = FdInvalid;
        g_tunFd = FdInvalid;
        LCLOSE_SOCKET(fd);
        if (g_tunReader.joinable()) g_tunReader.join();
        return "cannot start tun threads";
    }
    Logger::Get().Log(LogLevel::Info, "TUN engine started (fd=" + std::to_string(fd) + ")");
    return "";
}

void StopTun() {
    std::lock_guard<std::mutex> lk(g_tunStateMu);
    TunEngine& e = Engine();
    if (!e.running.load()) return;
    e.running.store(false);
    int fd = g_tunFd;
    g_tunFd = FdInvalid;
    e.tunFd = FdInvalid;
    if (fd >= 0) LCLOSE_SOCKET(fd);
    std::vector<std::shared_ptr<TcpFlow>> allFlows;
    std::vector<std::shared_ptr<UdpMapping>> allUdp;
    {
        std::lock_guard<std::mutex> lk2(e.mu);
        for (auto& kv : e.flows) allFlows.push_back(kv.second);
        e.flows.clear();
        for (auto& kv : e.udp) allUdp.push_back(kv.second);
        e.udp.clear();
    }
    for (auto& f : allFlows) {
        // Mark reaped first so the detached flow workers cannot re-register or
        // close the descriptor a second time, then drop the socket.
        f->reaped.store(true);
        {
            std::lock_guard<std::mutex> flk(f->fmu);
            f->state = FlowState::Closed;
        }
        f->sock.Close();
    }
    for (auto& m : allUdp) {
        m->Close();
    }
    // The maps were cleared wholesale, so the per-flow/per-mapping decrements
    // never ran; reset the counters instead of leaving them drifting upward.
    Stats().tcpConns.store(0);
    Stats().tcpConnsPeak.store(0);
    Stats().udpConns.store(0);
    if (g_tunReader.joinable()) g_tunReader.join();
    if (g_tunTimer.joinable()) g_tunTimer.join();
    Logger::Get().Log(LogLevel::Info, "TUN engine stopped");
}

bool TunRunning() { return Engine().running.load(); }

}  // namespace lcore

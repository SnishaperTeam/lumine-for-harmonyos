#include "ltunnel.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <exception>
#include <string>
#include <thread>

#include "lnet.h"
#include "ltypes.h"

namespace lcore {

// Global shutdown flag (owned by lcore.cpp). Relay/sniff loops poll it via
// their recv timeouts and abort promptly so Stop() can join quickly.
extern std::atomic<bool> gStopFlag;

namespace {

constexpr unsigned char kTlsRecordHandshake = 0x16;
constexpr unsigned char kTlsMajor = 0x03;
constexpr int kRelayRecvTimeoutMs = 1500;
constexpr int kMaxFragPieces = 128;  // cap config-driven record/segment counts

// recv up to max; -2 on transient timeout/blocked, -1 on hard error,
// 0 on EOF, else n>0.
int ReadSome(int fd, char* buf, int max) {
    int n = LRecv(fd, buf, max, 0);
    if (n < 0) {
        int e = TranslateErrno();
#ifdef _WIN32
        if (e == WSAETIMEDOUT || e == WSAEWOULDBLOCK) return -2;
#else
        if (e == EAGAIN || e == EWOULDBLOCK) return -2;
#endif
        return -1;
    }
    return n;
}

// One direction of a full-duplex proxy. Uses 1.5s recv timeouts purely to
// poll the global stop flag. Half-closes the destination on exit so the
// opposite thread observes EOF; never closes the sockets (Tunnel owns them).
void RelayCopy(int src, int dst, std::atomic<long long>* counter) {
    char buf[16384];
    for (;;) {
        if (gStopFlag.load()) break;
        int n = ReadSome(src, buf, static_cast<int>(sizeof(buf)));
        if (n < 0) {
            if (n == -2) continue;  // timeout: keep polling the stop flag
            break;                  // hard error
        }
        if (n == 0) break;  // clean EOF
        if (counter) counter->fetch_add(n);
        if (!WriteAll(dst, buf, static_cast<size_t>(n))) {
            break;
        }
    }
    LShutdown(dst, 1);  // SHUT_WR / SD_SEND
}

void Relay(int cfd, int dfd) {
    SetSockRcvTimeout(cfd, kRelayRecvTimeoutMs);
    SetSockRcvTimeout(dfd, kRelayRecvTimeoutMs);
    // A failure to spawn the second relay thread must not escape as an
    // exception: Tunnel() is called from detached worker threads, where an
    // uncaught throw inside a joinable std::thread would abort the process.
    std::thread a;
    std::thread b;
    try {
        a = std::thread(RelayCopy, cfd, dfd, &Stats().down);
        b = std::thread(RelayCopy, dfd, cfd, &Stats().up);
    } catch (...) {
        LShutdown(cfd, 0);
        LShutdown(dfd, 0);
        if (a.joinable()) a.join();
        if (b.joinable()) b.join();
        return;
    }
    a.join();
    b.join();
}

}  // namespace

bool LookLikeHttpMethod(const std::string& head) {
    static const char* methods[] = {"GET ",   "POST ",  "HEAD ", "PUT ", "DELETE ",
                                    "OPTIONS ", "TRACE ", "PATCH "};
    if (head.size() < 4) return false;
    for (const char* m : methods) {
        size_t cl = std::strlen(m);
        if (head.size() >= cl && std::memcmp(head.data(), m, cl) == 0) return true;
    }
    return false;
}

ParsedClientHello ParseClientHello(const std::string& data) {
    ParsedClientHello p;
    if (data.size() < 5) {
        p.err = "too short";
        return p;
    }
    if (static_cast<unsigned char>(data[0]) != kTlsRecordHandshake) {
        p.err = "not a TLS handshake record";
        return p;
    }
    if (static_cast<unsigned char>(data[1]) != kTlsMajor) {
        p.err = "not a standard TLS record";
        return p;
    }
    size_t recordLen = 5 + (static_cast<size_t>((static_cast<unsigned char>(data[3]) << 8) |
                                                static_cast<unsigned char>(data[4])));
    if (data.size() < recordLen) {
        p.err = "record length exceeds data size";
        return p;
    }
    size_t off = 5;
    if (recordLen - 5 < 4) {
        p.err = "handshake message too short";
        return p;
    }
    if (static_cast<unsigned char>(data[off]) != 0x01) {
        p.err = "not a ClientHello handshake";
        return p;
    }
    size_t hsLen = (static_cast<size_t>(static_cast<unsigned char>(data[off + 1])) << 16) |
                   (static_cast<size_t>(static_cast<unsigned char>(data[off + 2])) << 8) |
                   static_cast<size_t>(static_cast<unsigned char>(data[off + 3]));
    if (hsLen + 4 > recordLen - 5) {
        p.err = "handshake length exceeds record length";
        return p;
    }
    off += 4;
    if (hsLen < 2 + 32 + 1) {
        p.err = "ClientHello too short";
        return p;
    }
    p.prtVer[0] = static_cast<unsigned char>(data[off]);
    p.prtVer[1] = static_cast<unsigned char>(data[off + 1]);
    off += 2 + 32;
    if (off >= data.size()) {
        p.err = "unexpected end after Random";
        p.ok = true;  // prtVer still usable; caller decides
        return p;
    }
    size_t sidLen = static_cast<unsigned char>(data[off]);
    ++off;
    if (off + sidLen > data.size()) {
        p.err = "session_id exceeds data";
        p.ok = true;
        return p;
    }
    off += sidLen;
    if (off + 2 > data.size()) {
        p.err = "cannot read cipher_suites";
        p.ok = true;
        return p;
    }
    size_t csLen = (static_cast<size_t>(static_cast<unsigned char>(data[off]) << 8) |
                    static_cast<unsigned char>(data[off + 1]));
    off += 2;
    if (off + csLen > data.size()) {
        p.err = "cipher_suites exceed data";
        p.ok = true;
        return p;
    }
    off += csLen;
    if (off >= data.size()) {
        p.err = "cannot read compression_methods";
        p.ok = true;
        return p;
    }
    size_t cmLen = static_cast<unsigned char>(data[off]);
    ++off;
    if (off + cmLen > data.size()) {
        p.err = "compression_methods exceed data";
        p.ok = true;
        return p;
    }
    off += cmLen;
    p.sniStart = -1;
    if (off + 2 > data.size()) {
        p.ok = true;
        return p;
    }
    size_t extTotal = (static_cast<size_t>(static_cast<unsigned char>(data[off]) << 8) |
                       static_cast<unsigned char>(data[off + 1]));
    off += 2;
    if (off + extTotal > data.size()) {
        p.err = "extensions length exceeds data";
        p.ok = true;
        return p;
    }
    size_t extEnd = off + extTotal;
    while (off + 4 <= extEnd) {
        size_t extType = (static_cast<size_t>(static_cast<unsigned char>(data[off]) << 8) |
                          static_cast<unsigned char>(data[off + 1]));
        size_t extLen = (static_cast<size_t>(static_cast<unsigned char>(data[off + 2]) << 8) |
                         static_cast<unsigned char>(data[off + 3]));
        size_t ds = off + 4;
        size_t de = ds + extLen;
        if (de > extEnd) {
            p.err = "extension exceeds extensions block";
            p.ok = true;
            return p;
        }
        if (extType == 0x0033) p.hasKeyShare = true;
        if (extType == 0x00fe) p.hasECH = true;
        if (extType == 0x0000) {  // SNI
            if (extLen < 2) {
                p.err = "malformed SNI";
                p.ok = true;
                return p;
            }
            size_t listLen = (static_cast<size_t>(static_cast<unsigned char>(data[ds]) << 8) |
                              static_cast<unsigned char>(data[ds + 1]));
            if (listLen + 2 != extLen) {
                p.err = "SNI list length mismatch";
                p.ok = true;
                return p;
            }
            size_t cur = ds + 2;
            if (cur + 3 > de) {
                p.err = "SNI entry too short";
                p.ok = true;
                return p;
            }
            if (static_cast<unsigned char>(data[cur]) != 0) {
                p.err = "unsupported SNI name type";
                p.ok = true;
                return p;
            }
            size_t nameLen = (static_cast<size_t>(static_cast<unsigned char>(data[cur + 1]) << 8) |
                              static_cast<unsigned char>(data[cur + 2]));
            size_t nameStart = cur + 3;
            if (nameStart + nameLen > de) {
                p.err = "SNI name exceeds extension";
                p.ok = true;
                return p;
            }
            p.sniStart = static_cast<int>(nameStart);
            p.sniLen = static_cast<int>(nameLen);
        }
        off = de;
    }
    p.ok = true;
    return p;
}

void SendTLSAlert(int fd, const unsigned char prtVer[2], unsigned char desc, unsigned char level) {
    unsigned char alert[7] = {0x15, prtVer[0], prtVer[1], 0x00, 0x02, level, desc};
    (void)WriteAll(fd, reinterpret_cast<const char*>(alert), 7);
}

namespace {

// Returns a split position guaranteed to lie in [minFrom, data.size()).
// A missing/malformed SNI (sniStart == -1, or range out of bounds) falls
// back to the midpoint instead of feeding a negative offset into substr.
std::size_t SafeSplitPos(const std::string& data, int sniStart, int sniLen, std::size_t minFrom) {
    if (data.size() <= minFrom) return minFrom;
    if (sniStart >= 0 && sniLen > 0) {
        std::size_t s = static_cast<std::size_t>(sniStart);
        std::size_t l = static_cast<std::size_t>(sniLen);
        if (s < data.size() && l <= data.size() - s) {
            std::size_t dot = data.rfind('.', s + l - 1);
            std::size_t cut;
            if (dot == std::string::npos || dot < s) {
                cut = s + l / 2;
            } else {
                cut = dot;
            }
            if (cut >= minFrom && cut < data.size()) return cut;
        }
    }
    return minFrom + (data.size() - minFrom) / 2;
}

void SplitAndAppend(const std::string& data, std::size_t from, std::size_t to, const std::string& header /*empty=off*/,
                    int n, std::vector<std::string>& result) {
    if (n <= 0) return;
    bool addHeader = !header.empty();
    std::size_t len = to - from;
    if (n == 1 || len < static_cast<std::size_t>(n)) {
        std::string part = data.substr(from, len);
        if (addHeader) {
            std::string rec;
            rec.reserve(5 + part.size());
            rec.append(header);
            rec.push_back(static_cast<char>((part.size() >> 8) & 0xFF));
            rec.push_back(static_cast<char>(part.size() & 0xFF));
            rec.append(part);
            result.push_back(std::move(rec));
        } else {
            result.push_back(std::move(part));
        }
        return;
    }
    std::size_t base = len / static_cast<std::size_t>(n);
    for (int i = 0; i < n; ++i) {
        std::size_t start = from + static_cast<std::size_t>(i) * base;
        std::size_t end = (i == n - 1) ? to : start + base;
        std::string part = data.substr(start, end - start);
        if (addHeader) {
            std::string rec;
            rec.reserve(5 + part.size());
            rec.append(header);
            rec.push_back(static_cast<char>((part.size() >> 8) & 0xFF));
            rec.push_back(static_cast<char>(part.size() & 0xFF));
            rec.append(part);
            result.push_back(std::move(rec));
        } else {
            result.push_back(std::move(part));
        }
    }
}

bool WaitForAck(const HuiPolicy& pol) {
    if (!pol.waitForAck) return true;
    if (pol.sendIntervalMs > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(pol.sendIntervalMs));
    }
    return true;
}

}  // namespace

bool SendRecords(int fd, std::string& ch, int sniStart, int sniLen, const HuiPolicy& pol, std::string& err) {
    if (ch.size() < 5) {
        if (!WriteAll(fd, ch)) {
            err = "write";
            return false;
        }
        return true;
    }
    // OOB-ex mode requires at least 35 bytes; otherwise fall through raw.
    if (pol.oobEx && ch.size() < 35) {
        if (!WriteAll(fd, ch)) {
            err = "write";
            return false;
        }
        return true;
    }
    if (pol.minorVer >= 0 && pol.minorVer <= 0xFF) {
        ch[2] = static_cast<char>(pol.minorVer);
    }

    int records = pol.numRecords;
    int segments = pol.numSegments;
    if (records < 1) records = 1;
    if (segments == 0) segments = 1;
    // Config-controlled counts: clamp so a huge value cannot turn into
    // thousands of writes/sleeps tying up a worker thread.
    if (records > kMaxFragPieces) records = kMaxFragPieces;
    if (segments > kMaxFragPieces) segments = kMaxFragPieces;

    if (records == 1) {
        std::string payload = ch;
        int off = sniStart;
        if (pol.oobEx) {
            if (payload.size() >= 35) {
                // OOB is approximated as in-band writes for MVP.
                std::string head = payload.substr(0, 15);
                std::string tail = payload.substr(15);
                if (!WriteAll(fd, head)) { err = "oob 1"; return false; }
                payload = tail;
                off -= 15;  // SNI shifts with the stripped head; may go < 0
            }
        }
        if (segments == 1) {
            if (!WriteAll(fd, payload)) {
                err = "send remaining data";
                return false;
            }
            return true;
        }
        int leftSeg = segments / 2;
        int rightSeg = segments - leftSeg;
        std::size_t cut = SafeSplitPos(payload, off, sniLen, 0);
        std::vector<std::string> packets;
        SplitAndAppend(payload, 0, cut, "", leftSeg, packets);
        SplitAndAppend(payload, cut, payload.size(), "", rightSeg, packets);
        for (std::size_t i = 0; i < packets.size(); ++i) {
            if (!WriteAll(fd, packets[i])) {
                err = "write packet " + std::to_string(i + 1);
                return false;
            }
            if (!WaitForAck(pol)) return false;
        }
        return true;
    }

    if (ch.size() <= 5) {
        // No handshake payload to split: forward as-is.
        return WriteAll(fd, ch);
    }
    int leftChunks = records / 2;
    int rightChunks = records - leftChunks;
    std::vector<std::string> chunks;
    std::size_t cut = SafeSplitPos(ch, sniStart, sniLen, 5);
    std::string header = ch.substr(0, 3);
    SplitAndAppend(ch, 5, cut, header, leftChunks, chunks);
    SplitAndAppend(ch, cut, ch.size(), header, rightChunks, chunks);

    if (segments == -1) {
        for (std::size_t i = 0; i < chunks.size(); ++i) {
            (void)i;
            if (!WriteAll(fd, chunks[i])) {
                err = "write record " + std::to_string(i + 1);
                return false;
            }
            if (!WaitForAck(pol)) return false;
        }
        return true;
    }

    std::string merged;
    for (const auto& c : chunks) merged.append(c);
    if (pol.oobEx && merged.size() >= 35) {
        std::string head = merged.substr(0, 15);
        std::string tail = merged.substr(15);
        if (!WriteAll(fd, head)) { err = "oob 1"; return false; }
        merged = tail;
    }
    if (segments == 1 || merged.size() <= static_cast<std::size_t>(segments)) {
        (void)WriteAll(fd, merged);
        return true;
    }
    int baseLen = static_cast<int>(merged.size()) / segments;
    for (int i = 0; i < segments; ++i) {
        int start = i * baseLen;
        int end = (i == segments - 1) ? static_cast<int>(merged.size()) : start + baseLen;
        std::string seg = merged.substr(static_cast<std::size_t>(start), static_cast<std::size_t>(end - start));
        if (!WriteAll(fd, seg)) {
            err = "write segment " + std::to_string(i + 1);
            return false;
        }
        if (!WaitForAck(pol)) return false;
    }
    return true;
}

namespace {

// Closes the referenced fd on scope exit (including stack unwinding from a
// bad_alloc). cleanup() resets the int to -1 to hand ownership back early.
struct FdGuard {
    int& fd;
    explicit FdGuard(int& f) : fd(f) {}
    ~FdGuard() {
        if (fd >= 0) KillSocket(fd);
    }
};

bool DialIfNeeded(int& dstFd, const HuiPolicy& pol, const std::string& dstHost, int dstPort, std::string& err) {
    if (dstFd >= 0) return true;
    long long to = pol.connectTimeoutMs > 0 ? pol.connectTimeoutMs : 10000;
    dstFd = DialHostPort(dstHost, dstPort, to, err);
    return dstFd >= 0;
}

// Reads until data.size() >= want or EOF (returns current bytes). Blocks up to
// recvTimeoutMs per recv call; aborts on global stop between calls.
std::string RecvUpTo(int fd, std::size_t want, int recvTimeoutMs) {
    std::string buf;
    SetSockRcvTimeout(fd, recvTimeoutMs);
    char tmp[4096];
    while (buf.size() < want) {
        if (gStopFlag.load()) break;
        int n = ReadSome(fd, tmp, static_cast<int>(std::min(sizeof(tmp), want - buf.size())));
        if (n > 0) {
            buf.append(tmp, static_cast<std::size_t>(n));
        } else if (n == 0) {
            break;  // EOF
        } else {
            if (n == -1) break;  // hard error
            if (gStopFlag.load()) break;
        }
    }
    return buf;
}

}  // namespace

std::string RecvBytes(int fd, std::size_t want, int timeoutMs) {
    return RecvUpTo(fd, want, timeoutMs);
}

std::string ReadUntil(int fd, const std::string& delim, std::size_t limit, int timeoutMs) {
    std::string buf;
    SetSockRcvTimeout(fd, timeoutMs);
    char tmp[4096];
    for (;;) {
        if (gStopFlag.load()) break;
        if (!delim.empty() && buf.find(delim) != std::string::npos) break;
        if (buf.size() >= limit) break;
        std::size_t remaining = limit - buf.size();
        int want = static_cast<int>(std::min(sizeof(tmp), remaining));
        if (want <= 0) break;
        int n = ReadSome(fd, tmp, want);
        if (n > 0) {
            buf.append(tmp, static_cast<std::size_t>(n));
            if (!delim.empty() && buf.find(delim) != std::string::npos) break;
        } else if (n == 0) {
            break;
        } else if (gStopFlag.load()) {
            break;
        } else if (n == -1) {
            break;  // hard error
        }
    }
    return buf;
}

bool Tunnel(int clientFdIn, int dstFdIn, const HuiPolicy& pol,
            const std::string& dstHost, int dstPort,
            const std::string& originHost, int originPort,
            const std::string& label, std::string preBuffered) {
    int clientFd = clientFdIn;
    int dstFd = dstFdIn;
    FdGuard clientGuard(clientFd);
    FdGuard dstGuard(dstFd);
    try {
    std::string oldTarget = originHost + ":" + std::to_string(originPort);
    std::string err;

    auto cleanup = [&]() {
        if (clientFd >= 0) {
            KillSocket(clientFd);
            clientFd = -1;
        }
        if (dstFd >= 0) {
            KillSocket(dstFd);
            dstFd = -1;
        }
    };

    if (pol.mode == Mode::Raw) {
        if (!DialIfNeeded(dstFd, pol, dstHost, dstPort, err)) {
            Logger::Get().Log(LogLevel::Error, label + " dial " + oldTarget + " failed: " + err);
            cleanup();
            return false;
        }
        Relay(clientFd, dstFd);
        cleanup();
        return true;
    }

    // ---- sniff the first bytes on the client side ----
    const std::size_t sniffLenMin = 10;
    while (preBuffered.size() < sniffLenMin) {
        if (gStopFlag.load()) break;
        std::string more = RecvUpTo(clientFd, sniffLenMin - preBuffered.size(), 1500);
        if (more.empty()) break;
        preBuffered.append(more);
    }
    if (preBuffered.empty()) {
        Logger::Get().Log(LogLevel::Error, label + " empty tunnel");
        cleanup();
        return false;
    }

    // The sniff loop above may return with as little as one byte (EOF or a
    // stalled peer), so every later field access needs its own bound check:
    // the record header is 5 bytes and must exist before reading [3]/[4].
    bool isTLS = (preBuffered.size() >= 5 &&
                  static_cast<unsigned char>(preBuffered[0]) == kTlsRecordHandshake &&
                  static_cast<unsigned char>(preBuffered[1]) == kTlsMajor);
    Mode mode = (pol.mode == Mode::Unset) ? Mode::TLSRF : pol.mode;

    if (isTLS) {
        // Collect the full first TLS record.
        std::size_t recLen = 5 + (static_cast<std::size_t>(static_cast<unsigned char>(preBuffered[3]) << 8) |
                                  static_cast<unsigned char>(preBuffered[4]));
        while (preBuffered.size() < recLen) {
            std::string more = RecvUpTo(clientFd, recLen - preBuffered.size(), 1500);
            if (more.empty()) break;
            preBuffered.append(more);
        }
        if (preBuffered.size() < recLen) {
            Logger::Get().Log(LogLevel::Error, label + " truncated TLS record");
            cleanup();
            return false;
        }
        ParsedClientHello ph = ParseClientHello(preBuffered.substr(0, recLen));
        if (!ph.ok) {
            Logger::Get().Log(LogLevel::Warn, label + " parse ClientHello: " + ph.err + " (forward raw)");
            mode = Mode::Direct;
        } else {
            if (mode == Mode::TLSAlert) {
                SendTLSAlert(clientFd, ph.prtVer, 70, 2);  // access denied
                Stats().blocked++;
                cleanup();
                return false;
            }
            if (pol.tls13Only && !ph.hasKeyShare) {
                SendTLSAlert(clientFd, ph.prtVer, 49, 2);  // protocol version
                Logger::Get().Log(LogLevel::Info, label + " blocked: key_share missing");
                Stats().blocked++;
                cleanup();
                return false;
            }
            if (ph.hasECH) {
                Logger::Get().Log(LogLevel::Info, label + " ECH detected, direct");
                mode = Mode::Direct;
            } else if (ph.sniStart > 0 && ph.sniLen > 0) {
                std::string sni = preBuffered.substr(static_cast<std::size_t>(ph.sniStart), static_cast<std::size_t>(ph.sniLen));
                if (sni != originHost && !originHost.empty()) {
                    Logger::Get().Log(LogLevel::Info, label + " mismatched SNI: " + sni + " (ignore in mvp)");
                }
            } else {
                Logger::Get().Log(LogLevel::Info, label + " SNI not found, direct");
                mode = Mode::Direct;
            }
        }
        if (!DialIfNeeded(dstFd, pol, dstHost, dstPort, err)) {
            Logger::Get().Log(LogLevel::Error, label + " dial " + oldTarget + " failed: " + err);
            cleanup();
            return false;
        }
        std::string record = preBuffered.substr(0, recLen);
        bool ok = true;
        switch (mode) {
            case Mode::Direct:
            case Mode::Raw:
                ok = WriteAll(dstFd, record);
                break;
            case Mode::TTLD:
                Logger::Get().Log(LogLevel::Info, label + " ttl-d unsupported in mvp, fallback direct");
                ok = WriteAll(dstFd, record);
                break;
            case Mode::TLSRF:
            default:
                ok = SendRecords(dstFd, record, ph.sniStart, ph.sniLen, pol, err);
                if (!ok) Logger::Get().Log(LogLevel::Error, label + " tls fragment: " + err);
                break;
        }
        if (!ok) {
            cleanup();
            return false;
        }
        std::string tail = preBuffered.substr(recLen);
        if (!tail.empty() && !WriteAll(dstFd, tail)) {
            cleanup();
            return false;
        }
        Relay(clientFd, dstFd);
        cleanup();
        return true;
    }

    if (LookLikeHttpMethod(preBuffered)) {
        // Collect until \r\n\r\n. ReadUntil returns as soon as the delimiter is
        // seen; RecvUpTo would wait for the full 4096 bytes and stall forever on
        // requests pipelined by clients that then wait for the response.
        constexpr std::size_t kMaxHttpHead = 64 << 10;
        if (preBuffered.find("\r\n\r\n") == std::string::npos && preBuffered.size() < kMaxHttpHead) {
            std::size_t room = kMaxHttpHead - std::min(preBuffered.size(), kMaxHttpHead);
            std::string more = ReadUntil(clientFd, "\r\n\r\n", room, 1500);
            if (!more.empty()) {
                preBuffered.append(more);
            }
        }
        std::size_t headEnd = preBuffered.find("\r\n\r\n");
        std::string head = (headEnd == std::string::npos) ? preBuffered : preBuffered.substr(0, headEnd + 4);
        std::string body = (headEnd == std::string::npos) ? "" : preBuffered.substr(headEnd + 4);

        int hs = pol.httpStatus;
        if (hs > 0) {
            std::string statusText = "Unknown";
            switch (hs) {
                case 301: statusText = "Moved Permanently"; break;
                case 302: statusText = "Found"; break;
                case 403: statusText = "Forbidden"; break;
                case 404: statusText = "Not Found"; break;
                case 500: statusText = "Internal Server Error"; break;
                case 502: statusText = "Bad Gateway"; break;
                default: statusText = "HTTP Status"; break;
            }
            std::string resp;
            if (hs == 301 || hs == 302) {
                // Location derived from the request first-line target.
                std::string path = "/";
                if (head.size() >= 4) {
                    std::string firstLine = head.substr(0, head.find("\r\n"));
                    std::size_t sp1 = firstLine.find(' ');
                    std::size_t sp2 = (sp1 != std::string::npos) ? firstLine.find(' ', sp1 + 1) : std::string::npos;
                    if (sp2 != std::string::npos) {
                        std::string uri = firstLine.substr(sp1 + 1, sp2 - sp1 - 1);
                        std::size_t q = uri.find("://");
                        if (q != std::string::npos) {
                            std::size_t slash = uri.find('/', q + 3);
                            uri = (slash == std::string::npos) ? "/" : uri.substr(slash);
                        }
                        path = uri;
                    }
                }
                resp = "HTTP/1.1 " + std::to_string(hs) + " " + statusText + "\r\nLocation: https://" +
                       originHost + path + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            } else {
                resp = "HTTP/1.1 " + std::to_string(hs) + " " + statusText +
                       "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            }
            WriteAll(clientFd, resp);
            Logger::Get().Log(LogLevel::Info, label + " sent " + std::to_string(hs) + " " + statusText);
            Stats().blocked++;
            cleanup();
            return false;
        }

        if (!DialIfNeeded(dstFd, pol, dstHost, dstPort, err)) {
            std::string resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            WriteAll(clientFd, resp);
            Logger::Get().Log(LogLevel::Error, label + " dial " + oldTarget + " failed: " + err);
            cleanup();
            return false;
        }
        if (!WriteAll(dstFd, head)) {
            cleanup();
            return false;
        }
        if (!body.empty() && !WriteAll(dstFd, body)) {
            cleanup();
            return false;
        }
        Relay(clientFd, dstFd);
        cleanup();
        return true;
    }

    // Unknown protocol: forward whatever we have, then relay.
    if (!DialIfNeeded(dstFd, pol, dstHost, dstPort, err)) {
        Logger::Get().Log(LogLevel::Error, label + " dial " + oldTarget + " failed: " + err);
        cleanup();
        return false;
    }
    if (!preBuffered.empty() && !WriteAll(dstFd, preBuffered)) {
        cleanup();
        return false;
    }
    Relay(clientFd, dstFd);
    cleanup();
    return true;
    } catch (const std::exception& e) {
        Logger::Get().Log(LogLevel::Error, label + " tunnel exception: " + e.what());
        return false;
    } catch (...) {
        Logger::Get().Log(LogLevel::Error, label + " tunnel unknown exception");
        return false;
    }
}

}  // namespace lcore
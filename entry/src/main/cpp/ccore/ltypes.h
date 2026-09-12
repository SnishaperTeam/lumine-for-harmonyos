// Common types shared across the portable C++ core.
#ifndef LCORE_LTYPES_H
#define LCORE_LTYPES_H

#include <atomic>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace lcore {

constexpr int FdInvalid = -1;

enum class Mode { Unset, Raw, Direct, TLSRF, TTLD, Block, TLSAlert };
enum class DNSMode { Unset, PreferIPv4, PreferIPv6 };

// Validated + normalized policy. Zero/"empty" values mean "unset by user" so
// mergePolicies' first-set-wins keeps parity with the Go core.
struct HuiPolicy {
    Mode mode = Mode::Unset;
    DNSMode dnsMode = DNSMode::Unset;
    bool replyFirst = false;
    bool tls13Only = false;
    bool waitForAck = false;
    bool oob = false;
    bool oobEx = false;
    bool nat64 = false;
    int port = 0;         // 0 = unset
    int httpStatus = 0;   // 0 = unset
    int numRecords = 0;   // 0 = unset (treated as 1 at use)
    int numSegments = 0;  // 0 = unset (treated as 1)
    int minorVer = -1;    // -1 = unset
    int fakeTTL = 0;      // 0 = unset
    long long connectTimeoutMs = 0;  // 0 = unset
    long long sendIntervalMs = 0;    // 0 = unset
    long long fakeSleepMs = 0;       // 0 = unset
    long long dnsCacheTTLMs = 0;     // 0 = unset
    std::string host;                // "" = unset
    std::string mapTo;               // "" = unset
    std::string nat64Prefix;         // "" = unset

    bool HasHost() const { return !host.empty(); }
};

// First-set-wins merge, mirroring go/internal/core/mergePolicies.
HuiPolicy MergePolicies(const HuiPolicy& a, const HuiPolicy& b);

// Parses Go-style durations ("10s", "400ms", "1m30s" simplified). Returns 0 on error.
long long ParseDurationMs(const std::string& s);

enum class LogLevel { Debug, Info, Warn, Error };

bool ParseDurationMs(const std::string& s, long long& out);

struct SessionStats {
    std::atomic<long long> down{0};
    std::atomic<long long> up{0};
    std::atomic<long long> blocked{0};
    std::atomic<long long> tcpConns{0};
    std::atomic<long long> tcpConnsPeak{0};
    std::atomic<long long> udpConns{0};
    std::atomic<long long> startEpochMs{0};

    void AddTcp(int /*delta*/) {
        long long cur = ++tcpConns;
        long long peak = tcpConnsPeak.load(std::memory_order_relaxed);
        while (cur > peak && !tcpConnsPeak.compare_exchange_weak(peak, cur)) {
        }
    }
    void DecTcp() { --tcpConns; }
};

inline SessionStats& Stats() {
    static SessionStats s;
    return s;
}

// Logger facade. Implemented in lcore.cpp; writes rotating session logs +
// core.log tail file + in-memory ring for GetLogs(). Thread-safe.
class Logger {
  public:
    static Logger& Get();

    void SetLevel(LogLevel lv) { level_ = lv; }
    LogLevel Level() const { return level_; }
    void SetPrefix(const std::string& p) { prefix_ = p; }

    void Log(LogLevel lv, const std::string& msg);
    void Debug(const std::string& m) { Log(LogLevel::Debug, m); }
    void Info(const std::string& m) { Log(LogLevel::Info, m); }
    void Warn(const std::string& m) { Log(LogLevel::Warn, m); }
    void Error(const std::string& m) { Log(LogLevel::Error, m); }

    // Log text plus origin label ("CONNECT host") composition helper used by servers.
    static std::string Cat(const std::string& a, const std::string& b);

    std::string DrainLogs();
    void ResetRing();

    void SetWorkDir(const std::string& d);
    void SetFileEnabled(bool on);
    std::string FilePath() const;

  private:
    std::atomic<LogLevel> level_{LogLevel::Info};
    std::string prefix_;
    mutable std::mutex mu_;
    std::deque<std::string> ring_;
    std::string workdir_;
    bool fileEnabled_ = true;
    void AppendSessionLocked(const std::string& line);
    void AppendCoreLocked(const std::string& line);
};

}  // namespace lcore

#endif  // LCORE_LTYPES_H
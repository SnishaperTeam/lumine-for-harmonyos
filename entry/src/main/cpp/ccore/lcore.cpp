#include "lcore.h"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mutex>
#include <thread>

#include "lhttp.h"
#include "lmini_json.h"
#include "lnet.h"
#include "lroute.h"
#include "lsocks5.h"
#include "ltun.h"
#include "ltunnel.h"
#include "ltypes.h"

#ifdef LUMINE_OHOS
#include <hilog/log.h>
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "LumineNAPI"
#endif

namespace lcore {

std::atomic<bool> gStopFlag{false};

// Immutable config snapshot. Readers take a copy of the pointer, so a reload
// can never free the object underneath them.
std::shared_ptr<const Config> g_coreConfig;

std::shared_ptr<const Config> GetCoreConfig() { return g_coreConfig; }

long long NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

// ---------------------------------------------------------------- Logger ----

namespace {

constexpr std::size_t kRingMax = 500;
constexpr long long kRotateBytes = 1 << 20;
constexpr std::size_t kMaxConfigBytes = 4 << 20;

std::string Timestamp() {
    auto now = std::chrono::system_clock::now();
    auto tt = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
    std::tm tmv{};
#ifdef _WIN32
    localtime_s(&tmv, &tt);
#else
    localtime_r(&tt, &tmv);
#endif
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d.%03d", tmv.tm_year + 1900,
                  tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                  static_cast<int>(ms));
    return buf;
}

const char* LevelName(LogLevel lv) {
    switch (lv) {
        case LogLevel::Debug: return "DEBUG";
        case LogLevel::Info: return "INFO";
        case LogLevel::Warn: return "WARN";
        case LogLevel::Error: return "ERROR";
    }
    return "INFO";
}

void RotateIfNeeded(const std::string& path) {
    std::error_code ec;
    long long size = 0;
    try {
        size = static_cast<long long>(std::filesystem::file_size(path, ec));
    } catch (...) {
        return;
    }
    if (ec || size < kRotateBytes) return;
    auto removePath = [](const std::string& p) {
#ifdef _WIN32
        _unlink(p.c_str());
#else
        std::remove(p.c_str());
#endif
    };
    for (int i = 2; i >= 1; --i) {
        std::string to = path + "." + std::to_string(i);
        std::string from = (i == 1) ? path : path + "." + std::to_string(i - 1);
        removePath(to);
        if (std::filesystem::exists(from)) {
            std::rename(from.c_str(), to.c_str());
        }
    }
}

}  // namespace

Logger& Logger::Get() {
    static Logger l;
    return l;
}

void Logger::SetWorkDir(const std::string& d) {
    std::lock_guard<std::mutex> lk(mu_);
    workdir_ = d;
}

void Logger::SetFileEnabled(bool on) {
    std::lock_guard<std::mutex> lk(mu_);
    fileEnabled_ = on;
}

std::string Logger::FilePath() const {
    std::lock_guard<std::mutex> lk(mu_);
    if (workdir_.empty()) {
        return std::string();
    }
    return workdir_ + "/logs/lumine.log";
}

void Logger::Log(LogLevel lv, const std::string& msg) {
    std::string line = Timestamp() + " [" + LevelName(lv) + "] " + prefix_ + msg;
#ifdef LUMINE_OHOS
    OH_LOG_Print(LOG_APP, lv == LogLevel::Error ? LOG_ERROR : (lv == LogLevel::Warn ? LOG_WARN : LOG_INFO),
                 LOG_DOMAIN, LOG_TAG, "%{public}.*s", static_cast<int>(line.size()), line.c_str());
#endif
    std::lock_guard<std::mutex> lk(mu_);
    ring_.push_back(line);
    while (ring_.size() > kRingMax) ring_.pop_front();
    if (fileEnabled_ && !workdir_.empty()) {
        AppendSessionLocked(line);
        AppendCoreLocked(line);
    }
}

void Logger::AppendSessionLocked(const std::string& line) {
    try {
        std::string dir = workdir_ + "/logs";
        std::filesystem::create_directories(dir);
        std::string path = dir + "/lumine.log";
        RotateIfNeeded(path);
        std::ofstream f(path, std::ios::app);
        if (f) {
            f << line << "\n";
        }
    } catch (...) {
    }
}

void Logger::AppendCoreLocked(const std::string& line) {
    try {
        std::string path = workdir_ + "/core.log";
        std::ofstream f(path, std::ios::app);
        if (f) {
            f << line << "\n";
        }
    } catch (...) {
    }
}

std::string Logger::DrainLogs() {
    std::lock_guard<std::mutex> lk(mu_);
    std::string out;
    for (const auto& s : ring_) {
        out += s;
        out += '\n';
    }
    return out;
}

void Logger::ResetRing() {
    std::lock_guard<std::mutex> lk(mu_);
    ring_.clear();
}

std::string Logger::Cat(const std::string& a, const std::string& b) { return a + b; }

// ---------------------------------------------------------------- config ----

namespace {

// cfgName is selected by the UI, but it is interpolated straight into a path.
// Reject anything that could escape configs/ (separators, drive prefixes,
// traversal components) so a crafted name cannot read arbitrary .json files.
bool IsSafeConfigName(const std::string& name) {
    if (name.empty() || name.size() > 128) return false;
    if (name.front() == '.') return false;
    if (name.find('/') != std::string::npos || name.find('\\') != std::string::npos) return false;
    if (name.find("..") != std::string::npos) return false;
    for (char c : name) {
        if (static_cast<unsigned char>(c) < 0x20) return false;  // control chars
    }
    return true;
}

}  // namespace

bool ParseConfigFileInto(const std::string& dir, const std::string& cfgName, Config& out, std::string& err) {
    if (!IsSafeConfigName(cfgName)) {
        err = "load config error: invalid config name";
        return false;
    }
    std::string path = dir + "/configs/" + cfgName + ".json";
    std::ifstream in(path);
    if (!in) {
        err = "load config error: cannot open " + path;
        return false;
    }
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (text.size() > kMaxConfigBytes) {
        err = "load config error: config file too large";
        return false;
    }
    Json root;
    std::string jerr;
    if (!Json::Parse(text, root, jerr)) {
        err = "load config error: parse " + path + ": " + jerr;
        return false;
    }
    out = Config();
    std::string perr = ParseConfigJson(root, out);
    if (!perr.empty()) {
        err = "load config error: " + perr;
        return false;
    }
    return true;
}

bool ParseConfigFile(const std::string& dir, const std::string& cfgName, std::string& err) {
    // Build the replacement off to the side and publish it in one atomic
    // pointer store: a partially constructed Config must never be visible to
    // the proxy/TUN workers that read GetCoreConfig().
    auto next = std::make_shared<Config>();
    if (!ParseConfigFileInto(dir, cfgName, *next, err)) {
        return false;
    }
    g_coreConfig = next;
    return true;
}

// ---------------------------------------------------------------- lifecycle ---

namespace {

std::mutex g_stateMu;
std::string g_workDir;
bool g_running = false;
int g_socks5Lfd = FdInvalid;
int g_httpLfd = FdInvalid;
std::thread g_socks5Thr;
std::thread g_httpThr;
std::thread g_statsThr;

// Bound per-process proxy worker threads: every accepted connection also
// spawns two relay threads, so without a cap a flood of localhost connects
// (a malicious app on the device) can exhaust threads/memory.
constexpr int kMaxProxyWorkers = 256;
std::atomic<int> g_activeWorkers{0};

// Primary accept loop. proto: "socks5" | "http".
void AcceptLoop(int lfd, const char* proto) {
    while (!gStopFlag.load()) {
        int c = AcceptOne(lfd);
        if (c < 0) {
            if (gStopFlag.load()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
            continue;
        }
        if (g_activeWorkers.load() >= kMaxProxyWorkers) {
            KillSocket(c);  // shed load; clients retry/back off
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        g_activeWorkers.fetch_add(1);
        Stats().AddTcp(1);
        try {
            std::thread([c, proto]() {
                SetSockRcvTimeout(c, 10000);
                try {
                    if (std::string(proto) == "socks5") {
                        HandleSocks5(c);
                    } else {
                        HandleHttp(c);
                    }
                } catch (...) {
                    try {
                        KillSocket(c);
                    } catch (...) {
                    }
                }
                Stats().DecTcp();
                g_activeWorkers.fetch_sub(1);
            }).detach();
        } catch (...) {
            // Thread creation can fail under resource exhaustion; the accepted
            // connection is dropped instead of taking the accept loop down.
            KillSocket(c);
            Stats().DecTcp();
            g_activeWorkers.fetch_sub(1);
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
    // Listener fd is closed by CoreStop (not here): closing from this thread
    // would race with the shutdown in CoreStop.
}

void StatsLoop(const std::string workDir) {
    while (!gStopFlag.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
        if (gStopFlag.load()) break;
        long long upMs = NowMs() - Stats().startEpochMs;
        std::string body = "{\"down\":" + std::to_string(Stats().down.load()) +
                           ",\"up\":" + std::to_string(Stats().up.load()) +
                           ",\"blocked\":" + std::to_string(Stats().blocked.load()) +
                           ",\"tcp_conns\":" + std::to_string(Stats().tcpConns.load()) +
                           ",\"udp_conns\":" + std::to_string(Stats().udpConns.load()) +
                           ",\"uptime_ms\":" + std::to_string(upMs) + "}\n";
        try {
            std::string path = workDir + "/core_stats.json";
            std::ofstream f(path, std::ios::trunc);
            if (f) f << body;
        } catch (...) {
        }
    }
}

void ClearStatsFile(const std::string& workDir) {
    try {
        std::string path = workDir + "/core_stats.json";
#ifdef _WIN32
        _unlink(path.c_str());
#else
        std::remove(path.c_str());
#endif
    } catch (...) {
    }
}

}  // namespace

// Error strings returned through the C ABI: each calling thread gets its own
// stable buffer (NAPI copies immediately), avoiding a cross-thread race on a
// single global std::string.
thread_local std::string g_tlError;
const char* SetApiError(const std::string& s) {
    g_tlError = s;
    return g_tlError.c_str();
}

std::string CoreSetWorkingDir(const char* dir) {
    std::lock_guard<std::mutex> lk(g_stateMu);
    if (!dir || !*dir) {
        return "working directory not set";
    }
    g_workDir = dir;
    Logger::Get().SetWorkDir(g_workDir);
    return "";
}

std::string CoreStart(int fd, const char* cfgName) {
    // The whole transition runs under the state lock: previously listeners and
    // threads were created after releasing it, so a concurrent CoreStop()
    // could tear down a half-started core and leak the listener fds/threads.
    std::lock_guard<std::mutex> lk(g_stateMu);
    if (g_running) {
        return "";
    }
    if (g_workDir.empty()) {
        return "working directory not set";
    }

    bool tunStarted = false;
    int sfd = FdInvalid;
    int hfd = FdInvalid;
    auto fail = [&](const std::string& msg) -> std::string {
        if (g_statsThr.joinable()) g_statsThr.join();
        if (g_httpThr.joinable()) g_httpThr.join();
        if (g_socks5Thr.joinable()) g_socks5Thr.join();
        g_socks5Lfd = FdInvalid;
        g_httpLfd = FdInvalid;
        if (sfd >= 0) KillSocket(sfd);
        if (hfd >= 0) KillSocket(hfd);
        if (tunStarted) StopTun();
        gStopFlag.store(true);
        return msg;
    };

    std::string name = (cfgName && *cfgName) ? cfgName : "config";
    std::string perr;
    auto nextCfg = std::make_shared<Config>();
    if (!ParseConfigFileInto(g_workDir, name, *nextCfg, perr)) {
        return perr;
    }
    // Publish only after the listeners are up, so a failed start leaves the
    // previous snapshot (or none) in place.
    std::shared_ptr<const Config> cfgSnapshot = nextCfg;

    gStopFlag.store(false);  // before StartTun: its readers poll this flag

    if (fd >= 0) {
        std::string terr = StartTun(fd);
        if (!terr.empty()) {
            gStopFlag.store(true);
            return terr;
        }
        tunStarted = true;
    }

    if (!NetInitOnce()) {
        return fail("socket init failed");
    }
    ClearDnsCache();

    const Config& cfg = *nextCfg;
    std::string socks5 = cfg.socks5Addr.empty() ? "127.0.0.1:1080" : cfg.socks5Addr;
    std::string http = cfg.httpAddr.empty() ? "127.0.0.1:1225" : cfg.httpAddr;

    std::string err;
    sfd = CreateListener(socks5, 128, err);
    if (sfd < 0) {
        return fail("listen " + socks5 + " failed: " + err);
    }
    hfd = CreateListener(http, 128, err);
    if (hfd < 0) {
        return fail("listen " + http + " failed: " + err);
    }
    g_socks5Lfd = sfd;
    g_httpLfd = hfd;

    g_coreConfig = cfgSnapshot;

    Stats().down.store(0);
    Stats().up.store(0);
    Stats().blocked.store(0);
    Stats().tcpConns.store(0);
    Stats().tcpConnsPeak.store(0);
    Stats().udpConns.store(0);
    Stats().startEpochMs = NowMs();

    try {
        g_socks5Thr = std::thread(AcceptLoop, sfd, "socks5");
        g_httpThr = std::thread(AcceptLoop, hfd, "http");
        g_statsThr = std::thread(StatsLoop, g_workDir);
    } catch (const std::exception& e) {
        // std::thread construction fails on thread/memory exhaustion; letting
        // it escape through the C ABI would abort the whole app.
        gStopFlag.store(true);
        g_coreConfig.reset();
        g_socks5Lfd = FdInvalid;
        g_httpLfd = FdInvalid;
        KillSocket(sfd);
        KillSocket(hfd);
        if (g_statsThr.joinable()) g_statsThr.join();
        if (g_httpThr.joinable()) g_httpThr.join();
        if (g_socks5Thr.joinable()) g_socks5Thr.join();
        if (tunStarted) StopTun();
        return std::string("cannot start worker threads: ") + e.what();
    }

    g_running = true;

    Logger::Get().Log(LogLevel::Info, "Lumine native core starting (fd=" + std::to_string(fd) + ")");
    Logger::Get().Log(LogLevel::Info, "SOCKS5 listening on " + socks5);
    Logger::Get().Log(LogLevel::Info, "HTTP proxy listening on " + http);
    return "";
}

void CoreStop() {
    {
        std::lock_guard<std::mutex> lk(g_stateMu);
        if (!g_running) {
            ClearStatsFile(g_workDir);
            return;
        }
        g_running = false;
        gStopFlag.store(true);
        StopTun();
        int sfd = g_socks5Lfd;
        int hfd = g_httpLfd;
        g_socks5Lfd = FdInvalid;
        g_httpLfd = FdInvalid;
        // Closing the listener sockets is what makes a blocked accept() return
        // (shutdown() alone is not enough, notably on Windows).
        if (sfd >= 0) KillSocket(sfd);
        if (hfd >= 0) KillSocket(hfd);
        if (g_socks5Thr.joinable()) g_socks5Thr.join();
        if (g_httpThr.joinable()) g_httpThr.join();
        if (g_statsThr.joinable()) g_statsThr.join();
        ClearStatsFile(g_workDir);
    }
    Logger::Get().Log(LogLevel::Info, "Lumine native core stopped");
}

bool CoreIsRunning() {
    std::lock_guard<std::mutex> lk(g_stateMu);
    return g_running;
}

std::string CoreCheckConfig() {
    std::string err;
    if (g_workDir.empty()) {
        return "working directory not set";
    }
    // Validate into a throwaway Config: this entry point can be called while
    // the core is serving traffic, and must never swap the live snapshot.
    Config probe;
    if (!ParseConfigFileInto(g_workDir, "config", probe, err)) {
        return err;
    }
    return "";
}

std::string CoreVersion() { return "lumine-mvp-1.0.0-ohos-native"; }

std::string CoreGetLogs() { return Logger::Get().DrainLogs(); }

void CoreOnNetworkChanged() {
    ClearDnsCache();
    Logger::Get().Log(LogLevel::Info, "network changed: DNS cache cleared");
}

// ---------------------------------------------------------------- C API -----

extern "C" {

void LumineSetWorkingDir(const char* dir) { CoreSetWorkingDir(dir); }

const char* LumineStart(int fd, const char* cfgName) {
    return SetApiError(CoreStart(fd, cfgName));
}

void LumineStop(void) { CoreStop(); }

int LumineIsRunning(void) { return CoreIsRunning() ? 1 : 0; }

const char* LumineCheckConfig(void) {
    return SetApiError(CoreCheckConfig());
}

const char* LumineGetVersion(void) {
    return SetApiError(CoreVersion());
}

const char* LumineGetLogs(int maxChunks) {
    (void)maxChunks;
    return SetApiError(CoreGetLogs());
}

void LumineOnNetworkChanged(void) { CoreOnNetworkChanged(); }

void LumineSetLogFileEnabled(int enabled) { Logger::Get().SetFileEnabled(enabled != 0); }

const char* LumineLogFilePath(void) {
    return SetApiError(Logger::Get().FilePath());
}

void LumineFreeString(const char*) {
    // Strings are owned by the module; NAPI copies before returning.
}

}  // extern "C"

}  // namespace lcore
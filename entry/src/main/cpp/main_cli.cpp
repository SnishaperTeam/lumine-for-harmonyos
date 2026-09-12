#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#include "ccore/lcore.h"
#include "ccore/lnet.h"

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

int Run(const std::string& dir, const std::string& cfgName, bool selftest) {
    std::fprintf(stderr, "[diag] dir=%s name=%s selftest=%d\n", dir.c_str(), cfgName.c_str(), selftest ? 1 : 0);
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

    KillSocket(efd);
    echoThr.detach();
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

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
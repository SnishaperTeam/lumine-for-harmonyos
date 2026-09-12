#include "lhttp.h"

#include <cctype>
#include <cstdlib>
#include <string>

#include "lcore.h"
#include "lnet.h"
#include "lroute.h"
#include "ltunnel.h"
#include "ltypes.h"

namespace lcore {

namespace {

std::string ToLower(const std::string& s) {
    std::string out(s);
    for (auto& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

// Splits "host:port"; returns host and port (defaulted). port<0 if unspecified.
void SplitHostPort(const std::string& in, std::string& host, int& port, int defaultPort) {
    // IPv6 literal [::1]:8080
    if (!in.empty() && in[0] == '[') {
        std::size_t close = in.find(']');
        if (close != std::string::npos) {
            host = in.substr(1, close - 1);
            if (close + 1 < in.size() && in[close + 1] == ':') {
                port = std::atoi(in.c_str() + close + 2);
                return;
            }
            port = defaultPort;
            return;
        }
    }
    std::size_t colon = in.rfind(':');
    if (colon != std::string::npos && in.find(':') == colon) {
        host = in.substr(0, colon);
        port = std::atoi(in.c_str() + colon + 1);
        if (port <= 0) port = -1;
        return;
    }
    host = in;
    port = defaultPort;
}

void WriteResponse(int fd, const std::string& statusLine, const std::string& extraHeaders) {
    std::string resp = statusLine + extraHeaders + "Content-Length: 0\r\nConnection: close\r\n\r\n";
    WriteAll(fd, resp);
}

}  // namespace

void HandleHttp(int clientFd) {
    Logger& lg = Logger::Get();
    lg.Log(LogLevel::Info, "HTTP proxy new client connection from " + PeerAddr(clientFd));

    SetSockRcvTimeout(clientFd, 10000);

    std::string head = ReadUntil(clientFd, "\r\n\r\n", 64 << 10, 5000);
    if (head.empty() || (head.find("HTTP/1.") == std::string::npos && head.find("HTTPS/") == std::string::npos)) {
        lg.Log(LogLevel::Warn, "HTTP proxy: malformed request head");
        KillSocket(clientFd);
        return;
    }

    std::size_t headEnd = head.find("\r\n\r\n");
    std::string body = (headEnd == std::string::npos) ? "" : head.substr(headEnd + 4);
    std::string requestHead = (headEnd == std::string::npos) ? head : head.substr(0, headEnd + 4);

    std::size_t eol = requestHead.find("\r\n");
    std::string requestLine = requestHead.substr(0, eol);
    std::string method;
    std::string target;
    {
        std::size_t sp1 = requestLine.find(' ');
        std::size_t sp2 = (sp1 != std::string::npos) ? requestLine.find(' ', sp1 + 1) : std::string::npos;
        method = requestLine.substr(0, sp1);
        target = (sp2 != std::string::npos) ? requestLine.substr(sp1 + 1, sp2 - sp1 - 1)
                                            : requestLine.substr(sp1 + 1);
    }

    // Host header (for origin-form and for CONNECT fallback).
    std::string hostHeader;
    {
        std::string lower = ToLower(requestHead);
        std::size_t hp = lower.find("\r\nhost:");
        if (hp == std::string::npos) hp = lower.find("\nhost:");
        if (hp != std::string::npos) {
            std::size_t ls = requestHead.find("\r\n", hp);
            std::size_t le = requestHead.find("\r\n", ls + 2);
            hostHeader = requestHead.substr(ls + 2, le - ls - 2);
        }
    }

    bool isConnect = (ToLower(method) == "connect");

    std::string originHost;
    int originPort = 0;

    if (isConnect) {
        SplitHostPort(target, originHost, originPort, 443);
        if (originHost.empty() || originPort <= 0) {
            WriteResponse(clientFd, "HTTP/1.1 400 Bad Request\r\n", "");
            KillSocket(clientFd);
            return;
        }
    } else {
        // absolute-form "http://host[:port]/path" or origin-form "/path"
        if (target.size() >= 7 && (target.compare(0, 7, "http://") == 0 || target.compare(0, 8, "https://") == 0)) {
            std::size_t scheme = target.find("://");
            std::size_t pathStart = target.find('/', scheme + 3);
            std::string authority = (pathStart == std::string::npos) ? target.substr(scheme + 3)
                                                                     : target.substr(scheme + 3, pathStart - scheme - 3);
            int defPort = target.compare(0, 8, "https://") == 0 ? 443 : 80;
            SplitHostPort(authority, originHost, originPort, defPort);
        } else {
            SplitHostPort(hostHeader, originHost, originPort, 80);
            if (originHost.empty()) {
                WriteResponse(clientFd, "HTTP/1.1 400 Bad Request\r\n", "");
                KillSocket(clientFd);
                return;
            }
        }
        if (originPort <= 0) originPort = 80;
    }

    bool isIP = IsIP(originHost);
    RouteResult r = Route(GetCoreConfig(), originHost, isIP, false);

    if (isConnect) {
        if (r.failed) {
            lg.Log(LogLevel::Error, "CONNECT " + originHost + ": failed to resolve/map");
            WriteResponse(clientFd, "HTTP/1.1 502 Bad Gateway\r\n", "");
            KillSocket(clientFd);
            return;
        }
        if (r.blocked) {
            lg.Log(LogLevel::Info, "CONNECT blocked " + originHost);
            WriteResponse(clientFd, "HTTP/1.1 403 Forbidden\r\n", "");
            Stats().blocked++;
            KillSocket(clientFd);
            return;
        }
        WriteResponse(clientFd, "HTTP/1.1 200 Connection Established\r\n", "Proxy-agent: Lumine\r\n");
        std::string label = "HTTPS CONNECT " + PeerAddr(clientFd) + " -- " + originHost + ":" +
                            std::to_string(originPort) + " -> " + r.dstHost;
        // Any application bytes sent after CONNECT are passed straight through.
        std::string extra = head.substr(headEnd + 4);
        Tunnel(clientFd, -1, r.policy, r.dstHost, originPort, originHost, originPort, label, extra);
        return;
    }

    if (r.failed) {
        lg.Log(LogLevel::Error, "HTTP " + method + " " + originHost + ": failed to resolve/map");
        WriteResponse(clientFd, "HTTP/1.1 502 Bad Gateway\r\n", "");
        KillSocket(clientFd);
        return;
    }
    if (r.blocked) {
        lg.Log(LogLevel::Info, "HTTP " + method + " blocked " + originHost);
        WriteResponse(clientFd, "HTTP/1.1 403 Forbidden\r\n", "");
        Stats().blocked++;
        KillSocket(clientFd);
        return;
    }

    int dstPort = (ToLower(method) == "connect") ? originPort : originPort;
    std::string label = "HTTP " + method + " " + PeerAddr(clientFd) + " -- " + originHost + ":" +
                        std::to_string(originPort) + " -> " + r.dstHost;
    Tunnel(clientFd, -1, r.policy, r.dstHost, dstPort, originHost, originPort, label, requestHead + body);
}

}  // namespace lcore
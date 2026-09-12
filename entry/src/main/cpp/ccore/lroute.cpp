#include "lroute.h"

#include <chrono>
#include <cstring>
#include <map>
#include <mutex>

#include "lmatcher.h"
#include "lnet.h"

namespace lcore {

namespace {

Config* g_config = nullptr;

std::mutex g_dnsMu;
std::map<std::string, std::pair<std::string, long long>> g_dnsCache;  // host -> (ip, expiresMs)

long long NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

bool ResolveViaGetAddrInfo(const std::string& host, DNSMode pref, std::string& ipOut) {
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = nullptr;
    int gai = getaddrinfo(host.c_str(), nullptr, &hints, &res);
    if (gai != 0 || res == nullptr) {
        if (res) freeaddrinfo(res);
        return false;
    }
    bool wantV4 = (pref != DNSMode::PreferIPv6);
    // Prefer v4 unless prefer_ipv6. Keep a v6 fallback.
    for (int pass = 0; pass < 2; ++pass) {
        for (auto* r = res; r; r = r->ai_next) {
            char buf[INET6_ADDRSTRLEN] = {0};
            bool isV4 = (r->ai_family == AF_INET);
            if (pass == 0 && isV4 != wantV4) continue;
            if (pass == 1 && isV4 == wantV4) continue;
            const void* addr = isV4
                                   ? static_cast<const void*>(&reinterpret_cast<struct sockaddr_in*>(r->ai_addr)->sin_addr)
                                   : static_cast<const void*>(&reinterpret_cast<struct sockaddr_in6*>(r->ai_addr)->sin6_addr);
            inet_ntop(r->ai_family, addr, buf, sizeof(buf));
            ipOut = buf;
            freeaddrinfo(res);
            return true;
        }
    }
    freeaddrinfo(res);
    return false;
}

}  // namespace

const HuiPolicy& DefaultPolicyRef() {
    static HuiPolicy p;  // fallback empty policy (used only when config missing)
    return g_config ? g_config->defaultPolicy : p;
}

bool ResolveBootstrap(const std::string& host, std::string& ipOut) {
    bool cached = false;
    return ResolveHost(host, DNSMode::PreferIPv4, 0, ipOut, cached);
}

bool ResolveHost(const std::string& host, DNSMode pref, long long cacheTtlMs,
                 std::string& ipOut, bool& cached) {
    bool isIP = IsIP(host);
    if (isIP) {
        ipOut = host;
        cached = false;
        return true;
    }
    long long now = NowMs();
    {
        std::lock_guard<std::mutex> lk(g_dnsMu);
        auto it = g_dnsCache.find(host);
        if (it != g_dnsCache.end()) {
            if (cacheTtlMs <= 0 || it->second.second > now) {
                ipOut = it->second.first;
                cached = true;
                return true;
            }
            g_dnsCache.erase(it);
        }
    }
    std::string ip;
    if (!ResolveViaGetAddrInfo(host, pref, ip)) {
        return false;
    }
    if (cacheTtlMs > 0) {
        std::lock_guard<std::mutex> lk(g_dnsMu);
        g_dnsCache[host] = std::make_pair(ip, now + cacheTtlMs);
    }
    ipOut = ip;
    cached = false;
    return true;
}

void ClearDnsCache() {
    std::lock_guard<std::mutex> lk(g_dnsMu);
    g_dnsCache.clear();
}

namespace {

const char* kUnsetString = "\x00";

IpLookup IpRedirectImpl(const Config& cfg, const std::string& ip) {
    IpLookup out;
    out.mapped = ip;
    HuiPolicy found;
    if (!cfg.ips->Find(ip, found)) {
        return out;
    }
    out.found = true;
    out.pol = found;
    if (found.mapTo.empty() || found.mapTo == kUnsetString) {
        return out;
    }
    const std::string& mapTo = found.mapTo;
    if (mapTo[0] == '$') {  // ip pool tag
        out.error = true;
        return out;
    }
    if (mapTo.find('/') != std::string::npos) {
        bool ok = false;
        std::string mapped = TransformIP(ip, mapTo, ok);
        if (!ok) {
            out.error = true;
            return out;
        }
        out.mapped = mapped;
        return out;
    }
    out.mapped = mapTo;  // could be a domain or a literal IP
    return out;
}

}  // namespace

IpLookup IpRedirect(const Config& cfg, const std::string& ip) { return IpRedirectImpl(cfg, ip); }

RouteResult Route(const Config& cfg, const std::string& originHost, bool isIP,
                  bool returnWhenDomainNotFound) {
    RouteResult r;
    bool isIP_ = isIP || IsIP(originHost);

    if (isIP_) {
        IpLookup il = IpRedirectImpl(cfg, originHost);
        if (il.error) {
            r.failed = true;
            return r;
        }
        r.matchedIP = il.found;
        r.dstHost = il.mapped;
        r.policy = il.found ? MergePolicies(il.pol, cfg.defaultPolicy) : cfg.defaultPolicy;
        if (r.policy.mode == Mode::Block) {
            r.blocked = true;
            return r;
        }
        if (r.policy.mode == Mode::Unset) r.policy.mode = Mode::TLSRF;
        if (r.policy.dnsMode == DNSMode::Unset) r.policy.dnsMode = DNSMode::PreferIPv4;
        return r;
    }

    HuiPolicy domainPolicy;
    bool foundDomain = cfg.domains->Find(originHost, domainPolicy);
    r.matchedDomain = foundDomain;

    bool blockedByDomain = foundDomain && domainPolicy.mode == Mode::Block;
    r.policy = foundDomain ? MergePolicies(domainPolicy, cfg.defaultPolicy) : cfg.defaultPolicy;

    bool noRedirect = false;
    std::string policyHost = r.policy.host;
    if (!policyHost.empty() && policyHost[0] == '^') {
        noRedirect = true;
        policyHost = policyHost.substr(1);
    }

    std::string selectedHost;
    std::string dst;
    bool failed = false;

    if (policyHost.empty()) {
        std::string hs;
        bool inHosts = cfg.hosts->Find(originHost, hs);
        if (inHosts) {
            if (!hs.empty() && hs[0] == '^') {
                noRedirect = true;
                hs = hs.substr(1);
            }
            selectedHost = hs;
        }
        if (selectedHost.empty()) {
            if (returnWhenDomainNotFound) {
                r.domainNotFound = true;
                r.failed = false;
                r.dstHost.clear();
                r.policy = HuiPolicy{};
                return r;
            }
            bool cached = false;
            if (!ResolveHost(originHost, r.policy.dnsMode, r.policy.dnsCacheTTLMs, dst, cached)) {
                failed = true;
            }
        }
    } else {
        selectedHost = policyHost;
    }

    if (!failed && dst.empty()) {
        if (selectedHost == "self" || selectedHost.empty()) {
            // "self" keeps origin; empty after (unhandled) means origin too.
            dst = (selectedHost == "self") ? originHost : originHost;
        } else if (selectedHost[0] == '$') {
            failed = true;  // ip-pool tags unsupported in MVP
        } else if (selectedHost[0] == '?') {
            bool cached = false;
            if (!ResolveHost(selectedHost.substr(1), r.policy.dnsMode, r.policy.dnsCacheTTLMs, dst, cached)) {
                failed = true;
            }
        } else {
            dst = selectedHost;
        }
    }

    if (failed) {
        r.failed = true;
        return r;
    }
    r.dstHost = dst;

    if (!noRedirect) {
        if (!dst.empty() && IsIP(dst)) {
            IpLookup il = IpRedirectImpl(cfg, dst);
            if (il.error) {
                r.failed = true;
                return r;
            }
            if (il.found) {
                r.matchedIP = true;
                r.dstHost = il.mapped;
                if (foundDomain) {
                    r.policy = MergePolicies(MergePolicies(domainPolicy, il.pol), cfg.defaultPolicy);
                } else {
                    r.policy = MergePolicies(il.pol, cfg.defaultPolicy);
                }
                if (r.policy.mode == Mode::Block) {
                    r.blocked = true;
                    return r;
                }
            }
        }
    }

    if (blockedByDomain) {
        r.blocked = true;
        return r;
    }
    if (r.policy.mode == Mode::Unset) r.policy.mode = Mode::TLSRF;
    if (r.policy.dnsMode == DNSMode::Unset) r.policy.dnsMode = DNSMode::PreferIPv4;
    return r;
}

}  // namespace lcore
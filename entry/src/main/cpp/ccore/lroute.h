// Request routing (port of go policy.go genPolicy) + DNS resolution.
#ifndef LCORE_LROUTE_H
#define LCORE_LROUTE_H

#include <string>

#include "lmatcher.h"
#include "ltypes.h"

namespace lcore {

struct RouteResult {
    bool failed = false;
    bool blocked = false;
    bool domainNotFound = false;
    bool matchedDomain = false;
    bool matchedIP = false;
    std::string dstHost;       // IP or hostname to dial
    HuiPolicy policy;          // effective merged policy
};

struct IpLookup {
    bool found = false;
    bool error = false;        // e.g. ip-pool tag unsupported
    HuiPolicy pol;
    std::string mapped;        // post-map_to host (== input when no mapping)
};

IpLookup IpRedirect(const Config& cfg, const std::string& ip);

// Faithful port of genPolicy for the listen-only path.
RouteResult Route(const Config& cfg, const std::string& originHost, bool isIP,
                  bool returnWhenDomainNotFound);

const HuiPolicy& DefaultPolicyRef();

// System-resolver DNS with policy-scoped TTL cache.
bool ResolveHost(const std::string& host, DNSMode pref, long long cacheTtlMs,
                 std::string& ipOut, bool& cached);
void ClearDnsCache();

bool ResolveBootstrap(const std::string& host, std::string& ipOut);

}  // namespace lcore

#endif  // LCORE_LROUTE_H
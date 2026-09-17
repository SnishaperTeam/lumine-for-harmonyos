#include "lmatcher.h"

#include <cctype>
#include <cstdlib>
#include <cstring>

#include "lnet.h"

namespace lcore {

namespace {

// DoS guards for attacker-controlled rule keys (subscription configs):
// nested "(a|b)" groups multiply the output exponentially, and deep nesting
// grows the call stack. On any violation the rule is dropped (empty result).
constexpr size_t kMaxPatternLen = 1024;
constexpr int kMaxPatternDepth = 16;
constexpr size_t kMaxPatternExpansions = 256;

bool ExpandPatternImpl(const std::string& s, int depth, size_t& budget,
                       std::vector<std::string>& out) {
    if (depth > kMaxPatternDepth || s.size() > kMaxPatternLen) return false;

    size_t left = std::string::npos;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '(') {
            left = i;
            break;
        }
    }
    if (left == std::string::npos) {
        for (const auto& part : SplitByPipe(s)) {
            if (budget == 0) return false;
            --budget;
            out.push_back(part);
        }
        return true;
    }
    size_t right = std::string::npos;
    int parenDepth = 1;
    for (size_t i = left + 1; i < s.size(); ++i) {
        if (s[i] == '(') {
            ++parenDepth;
        } else if (s[i] == ')') {
            --parenDepth;
            if (parenDepth == 0) {
                right = i;
                break;
            }
        }
    }
    if (right == std::string::npos) return false;  // unbalanced parentheses

    std::string prefix = s.substr(0, left);
    std::string inner = s.substr(left + 1, right - left - 1);
    std::string suffix = s.substr(right + 1);

    std::vector<std::string> suffixResults;
    if (!ExpandPatternImpl(suffix, depth + 1, budget, suffixResults)) return false;

    for (const auto& part : SplitByPipe(inner)) {
        for (const auto& suff : suffixResults) {
            if (budget == 0) return false;
            --budget;
            out.push_back(prefix + part + suff);
        }
    }
    return true;
}

}  // namespace

std::vector<std::string> ExpandPattern(const std::string& s) {
    std::vector<std::string> out;
    size_t budget = kMaxPatternExpansions;
    if (!ExpandPatternImpl(s, 1, budget, out)) {
        return {};  // malformed or too-expansive pattern: drop the rule
    }
    return out;
}

// ------------- IP helpers -------------

bool IsIPv4(const std::string& s) { return s.find(':') == std::string::npos; }
bool IsIP(const std::string& s) {
    in_addr a;
    in6_addr a6;
    return inet_pton(AF_INET, s.c_str(), &a) == 1 || inet_pton(AF_INET6, s.c_str(), &a6) == 1;
}

namespace {

// Strict non-negative integer parse for the prefix length. Returns false on
// empty input, signs, non-digits or overflow (atoi accepted garbage silently).
bool ParsePrefixLen(const char* p, int& out) {
    if (!p || !*p) return false;
    long long v = 0;
    for (const char* q = p; *q; ++q) {
        if (*q < '0' || *q > '9') return false;
        v = v * 10 + (*q - '0');
        if (v > 128) return false;  // wider than the maximum legal v6 prefix
    }
    out = static_cast<int>(v);
    return true;
}

}  // namespace

int ParseIpOrCidr(const std::string& s, int& family, unsigned char out[16], int& bits) {
    bits = -1;
    size_t slash = s.find('/');
    std::string ip = (slash == std::string::npos) ? s : s.substr(0, slash);
    int parsedBits = -1;
    if (slash != std::string::npos) {
        if (!ParsePrefixLen(s.c_str() + slash + 1, parsedBits)) return -1;
    }
    in_addr a4;
    if (inet_pton(AF_INET, ip.c_str(), &a4) == 1) {
        if (parsedBits > 32) return -1;  // out-of-range prefix would read past out[4]
        family = 4;
        std::memcpy(out, &a4, 4);
        std::memset(out + 4, 0, 12);
        bits = (parsedBits < 0) ? 32 : parsedBits;
        return 0;
    }
    in6_addr a6;
    if (inet_pton(AF_INET6, ip.c_str(), &a6) == 1) {
        if (parsedBits > 128) return -1;
        family = 6;
        std::memcpy(out, &a6, 16);
        bits = (parsedBits < 0) ? 128 : parsedBits;
        return 0;
    }
    return -1;
}

namespace {
inline bool IpMatchBytes(const unsigned char* ip, const unsigned char* net, int bits) {
    int fullBytes = bits / 8;
    if (std::memcmp(ip, net, static_cast<size_t>(fullBytes)) != 0) return false;
    int rem = bits % 8;
    if (rem == 0) return true;
    unsigned char mask = static_cast<unsigned char>(0xFF << (8 - rem));
    return (ip[fullBytes] & mask) == (net[fullBytes] & mask);
}

inline int FindIPv4(const std::string& s) {
    in_addr a;
    return inet_pton(AF_INET, s.c_str(), &a) == 1 ? 4 : 6;
}
}  // namespace

void IpMatcher::Insert(const std::string& ipOrCidr, const HuiPolicy& pol) {
    Entry e;
    if (ParseIpOrCidr(ipOrCidr, e.family, e.net, e.bits) != 0) {
        return;  // malformed rule entry — skip like a failed addrtrie insert
    }
    e.pol = pol;
    entries_.push_back(std::move(e));
}

bool IpMatcher::Find(const std::string& ip, HuiPolicy& out) const {
    int wantFam = FindIPv4(ip) == 4 ? 4 : 6;
    in_addr a4;
    in6_addr a6;
    unsigned char ipBytes[16];
    if (wantFam == 4) {
        if (inet_pton(AF_INET, ip.c_str(), &a4) != 1) return false;
        std::memcpy(ipBytes, &a4, 4);
        std::memset(ipBytes + 4, 0, 12);
    } else {
        if (inet_pton(AF_INET6, ip.c_str(), &a6) != 1) return false;
        std::memcpy(ipBytes, &a6, 16);
    }
    int best = -1;
    bool found = false;
    for (size_t i = 0; i < entries_.size(); ++i) {
        const Entry& e = entries_[i];
        if (e.family != wantFam) continue;
        if (!IpMatchBytes(ipBytes, e.net, e.bits)) continue;
        if (e.bits >= best) {  // later equal-length inserts win (trie overwrite)
            best = e.bits;
            out = e.pol;
            found = true;
        }
    }
    return found;
}

// ------------- transformIP (port of go policy.go transformIP) -------------

std::string TransformIP(const std::string& ipStr, const std::string& targetNetStr, bool& ok) {
    ok = false;
    int fam = 0;
    unsigned char ip[16];
    int bits = 0;
    if (ParseIpOrCidr(ipStr, fam, ip, bits) != 0) return "";
    int netFam = 0;
    unsigned char netBytes[16];
    int netBits = 0;
    if (ParseIpOrCidr(targetNetStr, netFam, netBytes, netBits) != 0) return "";
    if (fam != netFam) return "";
    char prefix[128];
    const char* fmt = (fam == 4) ? "%d.%d.%d.%d" : "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x";
    const int totalBytes = (fam == 4) ? 4 : 16;
    unsigned char newBytes[16];
    for (int i = 0; i < totalBytes; ++i) {
        int bitPos = i * 8;
        if (netBits >= bitPos + 8) {
            newBytes[i] = netBytes[i];
        } else if (netBits <= bitPos) {
            newBytes[i] = ip[i];
        } else {
            int maskBits = netBits - bitPos;
            unsigned char mask = static_cast<unsigned char>(0xFF << (8 - maskBits));
            newBytes[i] = static_cast<unsigned char>((netBytes[i] & mask) | (ip[i] & ~mask));
        }
    }
    if (fam == 4) {
        snprintf(prefix, sizeof(prefix), fmt, newBytes[0], newBytes[1], newBytes[2], newBytes[3]);
    } else {
        int idx[16] = {0};
        std::memcpy(idx, newBytes, 16);
        snprintf(prefix, sizeof(prefix), fmt, idx[0], idx[1], idx[2], idx[3], idx[4], idx[5], idx[6], idx[7],
                 idx[8], idx[9], idx[10], idx[11], idx[12], idx[13], idx[14], idx[15]);
    }
    ok = true;
    return prefix;
}

// ------------- Policy parsing -------------

namespace {
int ModeFrom(const std::string& s) {
    if (s == "raw") return 1;
    if (s == "direct") return 2;
    if (s == "tls-rf") return 3;
    if (s == "ttl-d") return 4;
    if (s == "block") return 5;
    if (s == "tls-alert") return 6;
    return 0;
}
int DnsModeFrom(const std::string& s) {
    if (s == "prefer_ipv4") return 1;
    if (s == "prefer_ipv6") return 2;
    return 0;
}
}  // namespace

static int ToInt(double d) { return static_cast<int>(d); }

static void ParsePolicyObject(const Json& j, HuiPolicy& p) {
    if (!j.IsObject()) return;
    p.replyFirst = j.getBool("reply_first", false);
    p.tls13Only = j.getBool("tls13_only", false);
    p.waitForAck = j.getBool("wait_for_ack", false);
    p.oob = j.getBool("oob", false);
    p.oobEx = j.getBool("oob_ex", false);
    p.port = ToInt(j.getNumber("port", 0));
    p.httpStatus = ToInt(j.getNumber("http_status", 0));
    p.numRecords = ToInt(j.getNumber("num_records", 0));
    p.numSegments = ToInt(j.getNumber("num_segs", 0));
    if (const Json* v = j.find("minor_ver")) {
        if (v->type == Json::Type::Number) p.minorVer = ToInt(v->num);
    }
    p.fakeTTL = ToInt(j.getNumber("fake_ttl", 0));
    p.host = j.getString("host", "");
    p.mapTo = j.getString("map_to", "");

    std::string nat64 = j.getString("nat64_prefix", "");
    if (nat64 == "\x00" || nat64.empty() || nat64 == "off") {
        // stay disabled
    } else {
        std::string t = nat64;
        size_t b = t.find_first_not_of(" \t\r\n");
        size_t e = t.find_last_not_of(" \t\r\n");
        t = (b == std::string::npos) ? "" : t.substr(b, e - b + 1);
        if (!t.empty()) {
            p.nat64Prefix = t;
            p.nat64 = true;
        }
    }
    ParseDurationMs(j.getString("connect_timeout", ""), p.connectTimeoutMs);
    ParseDurationMs(j.getString("send_interval", ""), p.sendIntervalMs);
    ParseDurationMs(j.getString("fake_sleep", ""), p.fakeSleepMs);
    ParseDurationMs(j.getString("dns_cache_ttl", ""), p.dnsCacheTTLMs);

    int m = ModeFrom(j.getString("mode", ""));
    if (m) p.mode = static_cast<Mode>(m);
    int dm = DnsModeFrom(j.getString("dns_mode", ""));
    if (dm) p.dnsMode = static_cast<DNSMode>(dm);
    // sniff_override / attempts / max_ttl / single_timeout / ttl_cache_ttl:
    // accepted but not used by the listen-only MVP subset.
}

std::string ParseConfigJson(const Json& root, Config& cfg) {
    if (!root.IsObject()) {
        return "config root must be an object";
    }
    cfg.socks5Addr = root.getString("socks5_address", "");
    cfg.httpAddr = root.getString("http_address", "");
    cfg.logLevel = root.getString("log_level", "INFO");

    if (const Json* dp = root.find("default_policy")) {
        ParsePolicyObject(*dp, cfg.defaultPolicy);
    }

    if (const Json* hosts = root.find("hosts")) {
        if (hosts->IsObject()) {
            for (const auto& kv : hosts->obj) {
                for (const auto& elem : SplitBySemi(kv.first)) {
                    for (const auto& pat : ExpandPattern(elem)) {
                        cfg.hosts->Add(pat, kv.second.str);
                    }
                }
            }
        }
    }

    if (const Json* dps = root.find("domain_policies")) {
        if (dps->IsObject()) {
            for (const auto& kv : dps->obj) {
                HuiPolicy pol;
                ParsePolicyObject(kv.second, pol);
                for (const auto& elem : SplitBySemi(kv.first)) {
                    for (const auto& pat : ExpandPattern(elem)) {
                        cfg.domains->Add(pat, pol);
                    }
                }
            }
        }
    }

    if (const Json* ips = root.find("ip_policies")) {
        if (ips->IsObject()) {
            for (const auto& kv : ips->obj) {
                HuiPolicy pol;
                ParsePolicyObject(kv.second, pol);
                for (const auto& elem : SplitBySemi(kv.first)) {
                    for (const auto& ipOrNet : ExpandPattern(elem)) {
                        cfg.ips->Insert(ipOrNet, pol);
                    }
                }
            }
        }
    }

    if (const Json* dns = root.find("dns")) {
        cfg.dnsType = dns->getString("type", "");
        cfg.dnsAddr = dns->getString("addr", "");
    }
    return "";
}

}  // namespace lcore
// Pattern expansion + domain/IP matchers + config building.
// Porting go/internal/core/config.go and go/internal/addrtrie.
#ifndef LCORE_LMATCHER_H
#define LCORE_LMATCHER_H

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "lmini_json.h"
#include "ltypes.h"

namespace lcore {

// "*(a|b).tld;c.tld" -> expanded literal patterns. Faithful port of
// go/internal/core expandPattern + splitByPipe.
std::vector<std::string> ExpandPattern(const std::string& s);

inline std::vector<std::string> SplitByPipe(const std::string& s) {
    if (s.empty()) return {""};
    std::vector<std::string> r;
    std::string cur;
    for (char ch : s) {
        if (ch == '|') {
            r.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(ch);
        }
    }
    r.push_back(cur);
    return r;
}

inline std::vector<std::string> SplitBySemi(const std::string& s) {
    std::vector<std::string> r;
    std::string cur;
    for (char ch : s) {
        if (ch == ';') {
            r.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(ch);
        }
    }
    r.push_back(cur);
    return r;
}

// Exact replica of go/internal/addrtrie.DomainMatcher[Find] semantics:
//   pattern "foo.com"      -> exact match on "foo.com" only
//   pattern "*.foo.com"    -> wildcard match for any subdomain ("a.foo.com")
//   pattern "*foo.com"     -> exact + wildcard
//   pattern "*"            -> root wildcard (catch-all)
// exact match at the full domain wins; otherwise the deepmost wildcard node
// closer to the root wins; then root wildcard.
template <typename T>
class DomainMatcher {
  public:
    DomainMatcher() { root_ = std::make_unique<Node>(); }

    void Add(const std::string& pattern, const T& value) {
        if (pattern == "*") {
            root_->hasWild = true;
            root_->wild = value;
            return;
        }
        bool isWild = false, isExact = false;
        if (pattern.rfind("*.", 0) == 0) {
            isWild = true;
            InsertPattern(pattern.substr(2), value, isWild, false);
        } else if (pattern.rfind("*", 0) == 0) {
            isWild = isExact = true;
            InsertPattern(pattern.substr(1), value, true, true);
        } else {
            InsertPattern(pattern, value, false, true);
        }
    }

    bool Find(const std::string& domain, T& out) const {
        Node* node = root_.get();
        const T* wildcand = nullptr;
        bool hasCand = false;
        bool fully = true;
        for (int i = static_cast<int>(domain.size()) - 1; i >= 0;) {
            int j = LastDot(domain, i);
            std::string label;
            if (j == -1) {
                label = domain.substr(0, i + 1);
            } else {
                label = domain.substr(j + 1, i - j);
            }
            auto it = node->children.find(label);
            if (it == node->children.end()) {
                fully = false;
                break;
            }
            node = it->second.get();
            // Candidate wildcard at this node only applies when we still have a
            // parent label above it (j != -1), mirroring the Go trie.
            if (node != root_.get() && j != -1 && node->hasWild) {
                wildcand = &node->wild;
                hasCand = true;
            }
            i = (j == -1) ? -1 : j - 1;
        }
        if (fully && node->hasExact) {
            out = node->exact;
            return true;
        }
        if (hasCand) {
            out = *wildcand;
            return true;
        }
        if (root_->hasWild) {
            out = root_->wild;
            return true;
        }
        return false;
    }

  private:
    struct Node {
        std::map<std::string, std::unique_ptr<Node>> children;
        T exact{};
        bool hasExact = false;
        T wild{};
        bool hasWild = false;
    };
    static int LastDot(const std::string& s, int upto) {
        for (int i = upto; i >= 0; --i) {
            if (s[i] == '.') return i;
        }
        return -1;
    }
    void InsertPattern(const std::string& pattern, const T& value, bool isWild, bool isExact) {
        Node* node = root_.get();
        for (int i = static_cast<int>(pattern.size()) - 1; i >= 0;) {
            int j = LastDot(pattern, i);
            std::string label;
            if (j == -1) {
                label = pattern.substr(0, i + 1);
                i = -1;
            } else {
                label = pattern.substr(j + 1, i - j);
                i = j - 1;
            }
            auto it = node->children.find(label);
            if (it == node->children.end()) {
                node->children[label] = std::make_unique<Node>();
            }
            node = node->children[label].get();
        }
        if (isWild) {
            node->hasWild = true;
            node->wild = value;
        }
        if (isExact) {
            node->hasExact = true;
            node->exact = value;
        }
    }
    std::unique_ptr<Node> root_;
};

// Longest-prefix IP matcher (linear scan; entry list is small). Value indices
// into a per-matcher policy pool to mirror policy pointer semantics.
class IpMatcher {
  public:
    void Insert(const std::string& ipOrCidr, const HuiPolicy& pol);
    // ip is a dotted-quad (v4) or colon hex (v6) string.
    bool Find(const std::string& ip, HuiPolicy& out) const;
    size_t Count() const { return entries_.size(); }

  private:
    struct Entry {
        int family = 0;           // 4 or 6
        unsigned char net[16];    // network bytes (big-endian)
        int bits = 0;
        HuiPolicy pol;
    };
    std::vector<Entry> entries_;
};

// Parses "a.b.c.d", "a.b.c.d/nn", v6 forms. Returns 0 on success.
int ParseIpOrCidr(const std::string& s, int& family, unsigned char out[16], int& bits);

bool IsIPv4(const std::string& s);
bool IsIP(const std::string& s);

// IPv4-prefix substitution from Go's transformIP. ip and targetNet like
// "146.75.48.0/22"; returns mapped addr string. targetNet w/o '/' returns ip unchanged.
std::string TransformIP(const std::string& ipStr, const std::string& targetNetStr, bool& ok);

struct Config {
    std::string socks5Addr;
    std::string httpAddr;
    std::string logLevel;
    HuiPolicy defaultPolicy;
    std::unique_ptr<DomainMatcher<HuiPolicy>> domains;
    std::unique_ptr<DomainMatcher<std::string>> hosts;
    std::unique_ptr<IpMatcher> ips;
    std::string dnsType;   // "https"/"udp"/"system" etc (informational)
    std::string dnsAddr;

    Config()
        : domains(std::make_unique<DomainMatcher<HuiPolicy>>()),
          hosts(std::make_unique<DomainMatcher<std::string>>()),
          ips(std::make_unique<IpMatcher>()) {}
};

// Parses the Lumine config JSON into ready-to-use matchers. Returns "" on
// success or an error string (matching mobile StartLumine error shape).
std::string ParseConfigJson(const Json& root, Config& cfg);

}  // namespace lcore

#endif  // LCORE_LMATCHER_H
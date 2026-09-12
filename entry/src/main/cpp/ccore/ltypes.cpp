#include "ltypes.h"

#include <cctype>

namespace lcore {

HuiPolicy MergePolicies(const HuiPolicy& a, const HuiPolicy& b) {
    const HuiPolicy* list[2] = {&a, &b};
    HuiPolicy m;
    for (const HuiPolicy* p : list) {
        if (m.mode == Mode::Unset && p->mode != Mode::Unset) m.mode = p->mode;
        if (m.dnsMode == DNSMode::Unset && p->dnsMode != DNSMode::Unset) m.dnsMode = p->dnsMode;
        if (m.host.empty()) m.host = p->host;
        if (m.mapTo.empty()) m.mapTo = p->mapTo;
        if (m.nat64Prefix.empty()) m.nat64Prefix = p->nat64Prefix;
        if (m.port == 0) m.port = p->port;
        if (m.httpStatus == 0) m.httpStatus = p->httpStatus;
        if (m.numRecords == 0) m.numRecords = p->numRecords;
        if (m.numSegments == 0) m.numSegments = p->numSegments;
        if (m.minorVer == -1) m.minorVer = p->minorVer;
        if (m.fakeTTL == 0) m.fakeTTL = p->fakeTTL;
        if (m.connectTimeoutMs == 0) m.connectTimeoutMs = p->connectTimeoutMs;
        if (m.sendIntervalMs == 0) m.sendIntervalMs = p->sendIntervalMs;
        if (m.fakeSleepMs == 0) m.fakeSleepMs = p->fakeSleepMs;
        if (m.dnsCacheTTLMs == 0) m.dnsCacheTTLMs = p->dnsCacheTTLMs;
        if (!m.replyFirst) m.replyFirst = p->replyFirst;
        if (!m.tls13Only) m.tls13Only = p->tls13Only;
        if (!m.waitForAck) m.waitForAck = p->waitForAck;
        if (!m.oob) m.oob = p->oob;
        if (!m.oobEx) m.oobEx = p->oobEx;
        if (!m.nat64) m.nat64 = p->nat64;
    }
    if (m.mode == Mode::Unset) m.mode = Mode::TLSRF;
    if (m.dnsMode == DNSMode::Unset) m.dnsMode = DNSMode::PreferIPv4;
    return m;
}

namespace {

const char* SkipSpaces(const char* p, const char* end) {
    while (p < end && std::isspace(static_cast<unsigned char>(*p))) ++p;
    return p;
}

// Parses a non-negative double from [p,end).
const char* ParseNumber(const char* p, const char* end, double& out) {
    double v = 0;
    bool hasAnyDigit = false;
    while (p < end && std::isdigit(static_cast<unsigned char>(*p))) {
        v = v * 10 + static_cast<double>(*p - '0');
        hasAnyDigit = true;
        ++p;
    }
    if (p < end && *p == '.') {
        ++p;
        double frac = 0.1;
        while (p < end && std::isdigit(static_cast<unsigned char>(*p))) {
            v += static_cast<double>(*p - '0') * frac;
            frac *= 0.1;
            hasAnyDigit = true;
            ++p;
        }
    }
    if (!hasAnyDigit) return nullptr;
    out = v;
    return p;
}

const char* ParseUnit(const char* p, const char* end, double& multMs) {
    std::string u;
    while (p < end && std::isalpha(static_cast<unsigned char>(*p))) {
        u.push_back(*p);
        ++p;
    }
    if (u == "h") multMs = 3.6e6;
    else if (u == "m") multMs = 6.0e4;
    else if (u == "s") multMs = 1.0e3;
    else if (u == "ms") multMs = 1.0;
    else if (u == "us" || u == "\u00b5s") multMs = 1.0e-3;
    else if (u == "ns") multMs = 1.0e-6;
    else multMs = 1.0;  // bare number: seconds in Go duration grammar treatment
    return p;
}

}  // namespace

long long ParseDurationMs(const std::string& s) {
    const char* p = s.c_str();
    const char* end = p + s.size();
    double total = 0;
    bool any = false;
    while (p < end) {
        p = SkipSpaces(p, end);
        if (p >= end) break;
        double num = 0;
        const char* np = ParseNumber(p, end, num);
        if (np == nullptr) return 0;
        double mult = 1;
        p = ParseUnit(np, end, mult);
        total += num * mult;
        any = true;
    }
    return any ? static_cast<long long>(total) : 0;
}

bool ParseDurationMs(const std::string& s, long long& out) {
    long long v = ParseDurationMs(s);
    if (v == 0 && s.find_first_of("0123456789") == std::string::npos) {
        return false;
    }
    out = v;
    return true;
}

}  // namespace lcore
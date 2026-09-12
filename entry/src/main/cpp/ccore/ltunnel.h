// Tunnel: TLS/HTTP sniffing, TLS-RF fragmentation and full-duplex relay.
// Ports go tunnel.go (parseClientHello), fragment.go (sendRecords).
#ifndef LCORE_LTUNNEL_H
#define LCORE_LTUNNEL_H

#include <string>

#include "ltypes.h"

namespace lcore {

struct ParsedClientHello {
    bool ok = false;
    unsigned char prtVer[2] = {0, 0};
    int sniStart = -1;  // index into record buffer
    int sniLen = 0;
    bool hasKeyShare = false;
    bool hasECH = false;
    std::string err;
};

ParsedClientHello ParseClientHello(const std::string& record);

// Sends the (fragmented) ClientHello to fd per the TLS-RF policy. Faithful
// port of go sendRecords. Note: clientHello may be mutated (minor_ver).
bool SendRecords(int fd, std::string& clientHello, int sniStart, int sniLen, const HuiPolicy& pol, std::string& err);

void SendTLSAlert(int fd, const unsigned char prtVer[2], unsigned char desc, unsigned char level);

// Caller passes an optionally pre-dialed dstFd (-1 = dial here). preBuffered
// holds bytes already consumed from the client. Blocking relay loop; checks
// the global stop flag on timeouts.
bool Tunnel(int clientFd, int dstFd, const HuiPolicy& pol,
            const std::string& dstHost, int dstPort,
            const std::string& originHost, int originPort,
            const std::string& label, std::string preBuffered);

// True when the leading bytes of a stream look like an HTTP request method.
bool LookLikeHttpMethod(const std::string& head);

// Reads until <= want bytes are collected (EOF tolerated); returns what was
// read. Per-recv timeout + global-stop polling.
std::string RecvBytes(int fd, std::size_t want, int timeoutMs);

// Reads until `delim` appears (or EOF / limit reached); returned string
// includes the delimiter when found.
std::string ReadUntil(int fd, const std::string& delim, std::size_t limit, int timeoutMs);

}  // namespace lcore

#endif  // LCORE_LTUNNEL_H
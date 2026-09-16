// TUN engine: turns the vpnExtension tun fd into a userspace tun2socks.
// IPv4/IPv6 parse, UDP NAT, DNS hijack (172.19.0.2:53) and a minimal
// virtual TCP stack that reuses Route() + SendRecords() for policy traffic.
#ifndef LCORE_LTUN_H
#define LCORE_LTUN_H

#include <string>

namespace lcore {

// Takes ownership of fd. Returns "" on success, error message otherwise.
std::string StartTun(int fd);

// Stops the engine, closes every socket it opened and the tun fd.
void StopTun();

bool TunRunning();

}  // namespace lcore

#endif  // LCORE_LTUN_H

// SOCKS5 inbound server (port of go socks5.go handleSocks5).
#ifndef LCORE_LSOCKS5_H
#define LCORE_LSOCKS5_H

namespace lcore {

// Serves one SOCKS5 client connection on clientFd (blocking until finish).
void HandleSocks5(int clientFd);

}  // namespace lcore

#endif  // LCORE_LSOCKS5_H
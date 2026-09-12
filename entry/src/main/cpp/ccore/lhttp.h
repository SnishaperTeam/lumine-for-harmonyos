// HTTP proxy inbound server (port of go http.go handleHTTPProxy): CONNECT
// tunneling plus absolute-form / origin-form forwarding.
#ifndef LCORE_LHTTP_H
#define LCORE_LHTTP_H

namespace lcore {

// Serves one HTTP proxy client connection on clientFd (blocking until finish).
void HandleHttp(int clientFd);

}  // namespace lcore

#endif  // LCORE_LHTTP_H
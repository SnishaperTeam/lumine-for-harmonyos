// Core lifecycle + process-wide state + C API (mirrors go capi.go).
#ifndef LCORE_LCORE_H
#define LCORE_LCORE_H

#include <atomic>
#include <string>

#include "lmatcher.h"

namespace lcore {

// Global shutdown flag; relay/sniff loops poll it on their recv timeouts.
extern std::atomic<bool> gStopFlag;

long long NowMs();

// Process-wide parsed config (set by CoreStart / ParseConfigFile).
Config& GetCoreConfig();
bool ParseConfigFile(const std::string& dir, const std::string& cfgName, std::string& err);

// Lifecycle. CoreStart returns "" on success or a non-empty error string.
std::string CoreSetWorkingDir(const char* dir);
std::string CoreStart(int fd, const char* cfgName);
void CoreStop();
bool CoreIsRunning();
std::string CoreCheckConfig();          // "" ok
std::string CoreVersion();
std::string CoreGetLogs();               // last ring entries, newline-joined
void CoreOnNetworkChanged();

}  // namespace lcore

// C ABI surface consumed by the NAPI bridge (and the host CLI smoke binary).
extern "C" {

void LumineSetWorkingDir(const char* dir);
const char* LumineStart(int fd, const char* cfgName);
void LumineStop(void);
int LumineIsRunning(void);
const char* LumineCheckConfig(void);
const char* LumineGetVersion(void);
const char* LumineGetLogs(int maxChunks);
void LumineOnNetworkChanged(void);
void LumineSetLogFileEnabled(int enabled);
const char* LumineLogFilePath(void);
void LumineFreeString(const char* s);

}  // extern "C"

#endif  // LCORE_LCORE_H
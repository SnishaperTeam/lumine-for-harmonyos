// Lumine NAPI —— 原生 C++ 核心桥接层。
//
// 核心实现位于 ccore/（便携 C++17：JSON/匹配器/路由/隧道/监听服务器/
// 生命周期），通过 C ABI (lcore.h) 暴露给本 NAPI 模块。

#include "napi/native_api.h"

#include "lcore.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "LumineNAPI"

// Mirror of the core working dir, needed by LumineCheckConfigJson to stage
// the JSON under <workDir>/configs before calling ParseConfigFile.
static std::string g_napiWorkDir;

static std::string NapiGetString(napi_env env, napi_value val) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, val, &type) != napi_ok || type != napi_string) {
        return std::string();
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, val, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    // The UTF-8 getter writes len bytes plus a NUL, so the destination must be
    // one byte larger than the reported length.
    std::string str(len + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, val, &str[0], len + 1, &written) != napi_ok) {
        return std::string();
    }
    str.resize(written);
    return str;
}

static napi_value NapiOwnString(napi_env env, const std::string& str) {
    napi_value result = nullptr;
    if (napi_create_string_utf8(env, str.c_str(), str.length(), &result) != napi_ok) {
        napi_get_undefined(env, &result);
    }
    return result;
}

// LumineSetWorkingDir(dir: string): void
static napi_value NapiSetWorkingDir(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    std::string dir = NapiGetString(env, args[0]);
    g_napiWorkDir = dir;
    LumineSetWorkingDir(dir.c_str());
    return nullptr;
}

// LumineStart(fd: number, cfgName: string): string
//   fd >= 0: TUN 模式（本核心不支持，返回错误串）
//   fd < 0 : 本地监听模式（SOCKS5/HTTP 回环入站，无 TUN）
// 返回错误串，空串 = 成功。
static napi_value NapiStart(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return NapiOwnString(env, "LumineStart requires (fd, cfgName)");
    }
    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    std::string cfgName = NapiGetString(env, args[1]);
    const char* err = LumineStart(fd, cfgName.c_str());
    std::string result = (err != nullptr) ? std::string(err) : std::string();
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "LumineStart fd=%{public}d cfg=%{public}s err=%{public}s",
                 fd, cfgName.c_str(), result.c_str());
    return NapiOwnString(env, result);
}

// LumineStop(): void
static napi_value NapiStop(napi_env env, napi_callback_info info) {
    LumineStop();
    return nullptr;
}

// LumineIsRunning(): boolean
static napi_value NapiIsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, LumineIsRunning() != 0, &result);
    return result;
}

// LumineOnNetworkChanged(): void —— 底层网络切换后清空运行时缓存
static napi_value NapiOnNetworkChanged(napi_env env, napi_callback_info info) {
    LumineOnNetworkChanged();
    return nullptr;
}

// LumineCheckConfig(): string —— 校验当前 configs/config.json，空串 = 通过
static napi_value NapiCheckConfig(napi_env env, napi_callback_info info) {
    const char* err = LumineCheckConfig();
    return NapiOwnString(env, (err != nullptr) ? std::string(err) : std::string());
}

// LumineCheckConfigJson(json: string): string —— 校验任意配置 JSON（订阅下载用）
// 核心运行中时拒绝，避免临时文件替换进程内全局配置。
static napi_value NapiCheckConfigJson(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return NapiOwnString(env, "LumineCheckConfigJson requires (json)");
    }
    if (LumineIsRunning() != 0) {
        return NapiOwnString(env, "core is running, cannot validate config now");
    }
    if (g_napiWorkDir.empty()) {
        return NapiOwnString(env, "working directory not set");
    }
    std::string json = NapiGetString(env, args[0]);
    if (json.empty()) {
        return NapiOwnString(env, "empty config json");
    }
    std::string path = g_napiWorkDir + "/configs/_check.json";
    {
        std::ofstream f(path, std::ios::binary | std::ios::trunc);
        if (!f.is_open()) {
            return NapiOwnString(env, "cannot write temp config file");
        }
        f << json;
    }
    // Validate into a local Config so the check can never swap (or clear) the
    // snapshot a running core is serving traffic with, even if the core is
    // started between the guard above and this call.
    std::string err;
    lcore::Config probe;
    bool ok = lcore::ParseConfigFileInto(g_napiWorkDir, "_check", probe, err);
    std::remove(path.c_str());
    if (!ok) {
        return NapiOwnString(env, err);
    }
    return NapiOwnString(env, "");
}

// LumineGetVersion(): string
static napi_value NapiGetVersion(napi_env env, napi_callback_info info) {
    const char* v = LumineGetVersion();
    return NapiOwnString(env, (v != nullptr) ? std::string(v) : std::string());
}

// LumineGetLogs(maxChunks: number): string —— 取走内存环形日志
static napi_value NapiGetLogs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    int32_t maxChunks = 0;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &maxChunks);
    }
    const char* logs = LumineGetLogs(maxChunks);
    return NapiOwnString(env, (logs != nullptr) ? std::string(logs) : std::string());
}

// LumineSetLogFileEnabled(enabled: boolean): void
static napi_value NapiSetLogFileEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    bool enabled = false;
    napi_get_value_bool(env, args[0], &enabled);
    LumineSetLogFileEnabled(enabled ? 1 : 0);
    return nullptr;
}

// LumineLogFilePath(): string
static napi_value NapiLogFilePath(napi_env env, napi_callback_info info) {
    const char* p = LumineLogFilePath();
    return NapiOwnString(env, (p != nullptr) ? std::string(p) : std::string());
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"LumineSetWorkingDir",     nullptr, NapiSetWorkingDir,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineStart",             nullptr, NapiStart,             nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineStop",              nullptr, NapiStop,              nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineIsRunning",         nullptr, NapiIsRunning,         nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineOnNetworkChanged",  nullptr, NapiOnNetworkChanged,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineCheckConfig",       nullptr, NapiCheckConfig,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineCheckConfigJson",   nullptr, NapiCheckConfigJson,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineGetVersion",        nullptr, NapiGetVersion,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineGetLogs",           nullptr, NapiGetLogs,           nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineSetLogFileEnabled", nullptr, NapiSetLogFileEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"LumineLogFilePath",       nullptr, NapiLogFilePath,       nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "Lumine NAPI native C++ core registered, version %{public}s", LumineGetVersion());
    return exports;
}

EXTERN_C_START
static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "lumine_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLumineNapi(void) {
    napi_module_register(&g_module);
}
EXTERN_C_END
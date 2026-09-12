/**
 * liblumine_napi —— 进程内 C++ 原生核心桥接。
 *
 * 核心为 ccore/（便携 C++17）编译出的 NAPI 模块（liblumine_napi.so）：
 * - 本地监听模式：UI 进程内调用 LumineStart(-1, cfgName)（SOCKS5/HTTP 回环入站）
 * - TUN 模式：当前 C++ 核心不支持 TUN，LumineStart(fd >= 0) 返回错误串
 * 统计经 <workDir>/core_stats.json 落盘（1s ticker），
 * 会话日志经 <workDir>/logs/lumine.log 落盘，宿主文件轮询读取；
 * 核心内存环形日志经 LumineGetLogs 取走。
 */

/** 设置核心工作目录（应用沙箱 filesDir），须在 LumineStart 之前调用 */
export const LumineSetWorkingDir: (dir: string) => void;

/**
 * 启动核心，返回错误串（空串 = 成功）。
 * @param fd TUN 文件描述符；fd < 0 表示本地监听模式（SOCKS5/HTTP 回环入站）
 * @param cfgName 配置名（对应 <workDir>/configs/<cfgName>.json）
 */
export const LumineStart: (fd: number, cfgName: string) => string;

/** 停止核心（优雅停止引擎/监听器，清理统计文件与日志句柄） */
export const LumineStop: () => void;

/** 核心是否运行中 */
export const LumineIsRunning: () => boolean;

/** 底层网络切换后通知核心清空 DNS/反向解析/TTL 缓存 */
export const LumineOnNetworkChanged: () => void;

/** 校验 <workDir>/configs/config.json，返回错误串（空串 = 通过） */
export const LumineCheckConfig: () => string;

/**
 * 校验任意配置 JSON（订阅下载预检用），返回错误串（空串 = 通过）。
 * 临时写入 <workDir>/configs/_check.json 校验后删除；核心运行中时拒绝。
 */
export const LumineCheckConfigJson: (json: string) => string;

/** 核心版本号 */
export const LumineGetVersion: () => string;

/**
 * 取走核心内存环形日志，返回聚合文本。
 * @param maxChunks 最多取走的分块数，0 = 取走全部
 */
export const LumineGetLogs: (maxChunks: number) => string;

/** 开关核心落盘日志（<workDir>/logs/lumine.log） */
export const LumineSetLogFileEnabled: (enabled: boolean) => void;

/** 当前核心落盘日志文件路径 */
export const LumineLogFilePath: () => string;

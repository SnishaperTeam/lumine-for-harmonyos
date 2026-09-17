import { Want } from '@kit.AbilityKit';
import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LumineCore } from '../service/LumineCore';
import { NetworkMonitor } from '../service/NetworkMonitor';
import { StatusStore } from '../data/StatusStore';
import { BUNDLE_NAME, DEFAULT_CONFIG_NAME } from '../common/Constants';
import { VpnState, SessionStats, LogEntry, RuntimeStatus } from '../model/VpnTypes';

const DOMAIN = 0x0000;
const TAG = 'LumineExt';
const MAX_LOG_LINES_PER_PUMP = 100;

export default class LumineVpnExtAbility extends VpnExtensionAbility {
  private tunFd: number = -1;
  private configName: string = DEFAULT_CONFIG_NAME;
  private core: LumineCore = LumineCore.getInstance();
  private statusStore: StatusStore | null = null;
  private networkMonitor: NetworkMonitor = NetworkMonitor.getInstance();
  private vpnConn: vpnExtension.VpnConnection | null = null;
  private pumpTimer: number = -1;
  private watchdogTimer: number = -1;
  private crashCount: number = 0;
  private lastCrashTime: number = 0;
  private errored: boolean = false;
  private readonly CRASH_WINDOW: number = 60000;
  private readonly CRASH_THRESHOLD: number = 3;
  private readonly PUMP_INTERVAL: number = 1000;
  private readonly WATCHDOG_INTERVAL: number = 5000;

  onCreate(want: Want): void {
    this.configName = (want.parameters?.['configName'] as string) || DEFAULT_CONFIG_NAME;
    const store: StatusStore = StatusStore.getInstance(this.context);
    this.statusStore = store;
    hilog.info(DOMAIN, TAG, 'onCreate configName=%{public}s filesDir=%{public}s',
      this.configName, this.context.filesDir);

    store.writeVpnState({
      stage: RuntimeStatus.STARTING,
      updatedAt: Date.now()
    }).then(() => {
      this.launch();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'write starting state failed: %{public}s', String(err));
    });
  }

  private launch(): void {
    try {
      this.checkCircuitBreaker();
    } catch (e) {
      this.handleError(String(e));
      return;
    }
    this.startVpn();
  }

  private checkCircuitBreaker(): void {
    const now = Date.now();
    if (now - this.lastCrashTime > this.CRASH_WINDOW) {
      this.crashCount = 0;
    }
    if (this.crashCount >= this.CRASH_THRESHOLD) {
      throw new Error('熔断：短时间内多次异常退出，已停止自动恢复');
    }
  }

  private async startVpn(): Promise<void> {
    const filesDir = this.context.filesDir;

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [
        { address: { address: '172.19.0.1', family: 1 }, prefixLength: 30 },
        { address: { address: 'fd66:6c75:6d69::1', family: 2 }, prefixLength: 64 }
      ],
      mtu: 1500,
      dnsAddresses: ['172.19.0.2'],
      isIPv6Accepted: true,
      routes: []
    };

    try {
      const conn = vpnExtension.createVpnConnection(this.context);
      this.vpnConn = conn;
      const fd: number = await conn.create(vpnConfig);
      this.tunFd = fd;
      hilog.info(DOMAIN, TAG, 'vpn connection created, tunFd=%{public}d', fd);

      const startErr = this.core.start(filesDir, this.configName, fd);
      if (startErr) {
        throw new Error('核心启动失败: ' + startErr);
      }
      hilog.info(DOMAIN, TAG, 'core process started, tunFd=%{public}d', fd);

      await this.statusStore!.writeVpnState({
        stage: RuntimeStatus.RUNNING,
        updatedAt: Date.now()
      });

      this.errored = false;
      this.startPump();
      this.startWatchdog();
      this.startNetworkMonitor();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startVpn failed: %{public}s', String(e));
      await this.handleError('VPN 创建失败: ' + String(e));
    }
  }

  private startPump(): void {
    this.pumpTimer = setInterval(async () => {
      try {
        if (!this.core.isRunning()) {
          hilog.error(DOMAIN, TAG, 'pump detected core stopped');
          await this.handleError('核心已停止');
          return;
        }

        const statsStr = this.core.readStats();
        const logsStr = this.core.readNewLogs();

        let stats: SessionStats = { down: 0, up: 0, blocked: 0, tcp_conns: 0, udp_conns: 0, uptime_ms: 0 };
        try {
          stats = JSON.parse(statsStr) as SessionStats;
        } catch {
        }

        const state: VpnState = {
          stage: RuntimeStatus.RUNNING,
          updatedAt: Date.now(),
          stats: stats
        };
        await this.statusStore!.writeVpnState(state);

        if (logsStr) {
          const logLines = logsStr.split('\n').filter((l: string) => l.length > 0);
          const batch = logLines.length > MAX_LOG_LINES_PER_PUMP
            ? logLines.slice(logLines.length - MAX_LOG_LINES_PER_PUMP)
            : logLines;
          for (const line of batch) {
            const entry: LogEntry = {
              raw: line,
              timestamp: Date.now(),
              level: this.extractLogLevel(line)
            };
            await this.statusStore!.appendLog(entry);
          }
        }
      } catch {
      }
    }, this.PUMP_INTERVAL);
  }

  private extractLogLevel(line: string): string {
    if (line.includes('ERROR') || line.includes('error')) return 'ERROR';
    if (line.includes('WARN') || line.includes('warn')) return 'WARN';
    return 'INFO';
  }

  private startWatchdog(): void {
    this.watchdogTimer = setInterval(async () => {
      try {
        if (!this.core.isRunning()) {
          hilog.error(DOMAIN, TAG, 'watchdog detected core stopped');
          await this.handleError('看门狗检测到核心异常');
        }
      } catch {
      }
    }, this.WATCHDOG_INTERVAL);
  }

  private startNetworkMonitor(): void {
    this.networkMonitor.setCallback(() => {
      this.core.onNetworkChanged();
    });
    this.networkMonitor.start();
  }

  private async handleError(error: string): Promise<void> {
    if (this.errored) {
      return;
    }
    this.errored = true;
    this.crashCount++;
    this.lastCrashTime = Date.now();
    hilog.error(DOMAIN, TAG, 'handleError: %{public}s', error);
    try {
      await this.statusStore!.writeVpnState({
        stage: RuntimeStatus.ERROR,
        updatedAt: Date.now(),
        error: error
      });
      await this.cleanup();
      await this.stopVpn();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'handleError cleanup failed: %{public}s', String(e));
    }
  }

  private async stopVpn(): Promise<void> {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: 'LumineVpnExtAbility'
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopVpnExtensionAbility failed: %{public}s', String(e));
    }
  }

  private async cleanup(): Promise<void> {
    if (this.pumpTimer >= 0) {
      clearInterval(this.pumpTimer);
      this.pumpTimer = -1;
    }
    if (this.watchdogTimer >= 0) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
    this.networkMonitor.stop();
    if (this.core.isRunning()) {
      this.core.stop();
    }
    this.tunFd = -1;
    if (this.vpnConn) {
      try {
        await this.vpnConn.destroy();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'destroy vpn connection failed: %{public}s', String(e));
      }
      this.vpnConn = null;
    }
  }

  async onDestroy(): Promise<void> {
    await this.cleanup();
    if (!this.errored) {
      await this.statusStore!.writeVpnState({
        stage: RuntimeStatus.IDLE,
        updatedAt: Date.now()
      });
    }
  }
}

@ObservedV2
export class ConfigViewModel {
  @Trace currentConfigJson: string = '{}';
  @Trace configList: string[] = [];
  @Trace selectedConfigName: string = 'config';
  @Trace disabledRuleKeys: string[] = [];
  @Trace vpnStage: string = 'idle';
  @Trace statsJson: string = '{}';
  @Trace logsJson: string = '[]';
  @Trace isLogCaptureEnabled: boolean = true;
  @Trace logMessage: string | null = null;

  get currentConfigParsed(): Record<string, unknown> {
    try {
      return JSON.parse(this.currentConfigJson) as Record<string, unknown>;
    } catch {
      return {};
    }
  }

  get statsParsed(): Record<string, number> {
    try {
      return JSON.parse(this.statsJson) as Record<string, number>;
    } catch {
      return { down: 0, up: 0, blocked: 0, tcp_conns: 0, udp_conns: 0, uptime_ms: 0 };
    }
  }

  get logsParsed(): Array<Record<string, unknown>> {
    try {
      return JSON.parse(this.logsJson) as Array<Record<string, unknown>>;
    } catch {
      return [];
    }
  }

  updateConfig(json: string): void {
    this.currentConfigJson = json;
  }

  updateConfigList(list: string[]): void {
    this.configList = list;
  }

  updateSelectedConfig(name: string): void {
    this.selectedConfigName = name;
  }

  updateDisabledRules(keys: string[]): void {
    this.disabledRuleKeys = keys;
  }

  updateVpnStage(stage: string): void {
    this.vpnStage = stage;
  }

  updateStats(json: string): void {
    this.statsJson = json;
  }

  updateLogs(json: string): void {
    this.logsJson = json;
  }

  toggleLogCapture(): void {
    this.isLogCaptureEnabled = !this.isLogCaptureEnabled;
  }

  setLogMessage(msg: string | null): void {
    this.logMessage = msg;
  }
}

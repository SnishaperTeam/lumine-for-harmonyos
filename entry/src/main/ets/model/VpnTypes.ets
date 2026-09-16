export enum RuntimeStatus {
  IDLE = 'idle',
  STARTING = 'starting',
  RUNNING = 'running',
  STOPPING = 'stopping',
  ERROR = 'error'
}

export interface SessionStats {
  down: number;
  up: number;
  blocked: number;
  tcp_conns: number;
  udp_conns: number;
  uptime_ms: number;
}

export interface LogEntry {
  raw: string;
  timestamp: number;
  level: string;
}

export interface NAT64Profile {
  id: string;
  name: string;
  prefix: string;
}

export interface SubscriptionProfile {
  id: string;
  name: string;
  url: string;
  configName: string;
  updatedAt: number;
}

export interface EvoEntry {
  id: string;
  target: string;
  timestamp: number;
  success: boolean;
  detail: string;
}

export interface DisabledRuleSnapshot {
  configName: string;
  disabledKeys: string[];
}

export interface VpnState {
  stage: string;
  updatedAt: number;
  error?: string;
  stats?: SessionStats;
}

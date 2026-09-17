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

export function sanitizeNAT64Profiles(raw: string): NAT64Profile[] {
  const out: NAT64Profile[] = [];
  if (raw.length === 0) {
    return out;
  }
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(raw) as Object;
  } catch (err) {
    return out;
  }
  if (!Array.isArray(parsed)) {
    return out;
  }
  for (const item of parsed as Object[]) {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const source = item as Record<string, Object>;
    const name = typeof source['name'] === 'string' ? source['name'] as string : '';
    const prefix = typeof source['prefix'] === 'string' ? source['prefix'] as string : '';
    if (name.length === 0 || prefix.length === 0) {
      continue;
    }
    const id = typeof source['id'] === 'string' && (source['id'] as string).length > 0
      ? source['id'] as string
      : prefix;
    const profile: NAT64Profile = { id: id, name: name, prefix: prefix };
    out.push(profile);
  }
  return out;
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

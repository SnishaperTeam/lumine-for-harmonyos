import { connection, socket } from '@kit.NetworkKit';

export function expandPrefixGroups(prefix: string): number[] | null {
  const p = prefix.includes('/') ? prefix.substring(0, prefix.indexOf('/')) : prefix;
  let groups: string[];
  if (p.includes('::')) {
    const parts = p.split('::');
    if (parts.length > 2) {
      return null;
    }
    const left = parts[0].length > 0 ? parts[0].split(':') : [];
    const right = parts.length === 2 && parts[1].length > 0 ? parts[1].split(':') : [];
    if (left.length + right.length > 7) {
      return null;
    }
    groups = [];
    for (let i = 0; i < 8; i++) {
      if (i < left.length) {
        groups.push(left[i]);
      } else if (i < 8 - right.length) {
        groups.push('0');
      } else {
        groups.push(right[i - (8 - right.length)]);
      }
    }
  } else {
    groups = p.split(':');
    if (groups.length !== 8) {
      return null;
    }
  }
  const out: number[] = [];
  for (let i = 0; i < 8; i++) {
    const v = parseInt(groups[i], 16);
    if (isNaN(v) || v < 0 || v > 0xffff) {
      return null;
    }
    out.push(v);
  }
  return out;
}

export function mapNat64(ipv4: string, prefix: string): string | null {
  const segs = ipv4.split('.');
  if (segs.length !== 4) {
    return null;
  }
  const bytes: number[] = [];
  for (let i = 0; i < 4; i++) {
    const v = Number(segs[i]);
    if (isNaN(v) || v < 0 || v > 255) {
      return null;
    }
    bytes.push(v);
  }
  const g = expandPrefixGroups(prefix);
  if (g === null) {
    return null;
  }
  const h6 = (bytes[0] << 8) | bytes[1];
  const h7 = (bytes[2] << 8) | bytes[3];
  const groups = [g[0], g[1], g[2], g[3], g[4], g[5], h6, h7];
  return groups.map((v: number) => v.toString(16)).join(':');
}

const IPV6_PROBE_HOST = '2606:4700:4700::1111';
const IPV6_PROBE_PORT = 443;
const IPV6_PROBE_TIMEOUT_MS = 3000;
const DETECT_CACHE_TTL_MS = 60000;
const DEBOUNCE_MS = 500;

export class NetworkMonitor {
  private static instance: NetworkMonitor | null = null;
  private callback: (() => void) | null = null;
  private netConn: connection.NetConnection | null = null;
  private debounceTimer: number = -1;
  private ipv6Cache: boolean | null = null;
  private ipv6CacheAt: number = 0;
  private nat64Cache: string | null = null;
  private nat64CacheAt: number = 0;

  static getInstance(): NetworkMonitor {
    if (!NetworkMonitor.instance) {
      NetworkMonitor.instance = new NetworkMonitor();
    }
    return NetworkMonitor.instance;
  }

  setCallback(cb: () => void): void {
    this.callback = cb;
  }

  start(): void {
    this.netConn = connection.createNetConnection();
    this.netConn.register(() => {
    });
    this.netConn.on('netAvailable', (data: connection.NetHandle) => {
      this.scheduleNotify();
    });
    this.netConn.on('netLost', (data: connection.NetHandle) => {
      this.scheduleNotify();
    });
    this.netConn.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
      this.scheduleNotify();
    });
  }

  stop(): void {
    if (this.netConn) {
      this.netConn.unregister(() => {
      });
      this.netConn = null;
    }
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  private scheduleNotify(): void {
    this.invalidateCache();
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      if (this.callback) {
        this.callback();
      }
    }, DEBOUNCE_MS);
  }

  private invalidateCache(): void {
    this.ipv6Cache = null;
    this.nat64Cache = null;
  }

  async checkIpv6Available(force: boolean = false): Promise<boolean> {
    const now = Date.now();
    if (!force && this.ipv6Cache !== null && now - this.ipv6CacheAt < DETECT_CACHE_TTL_MS) {
      return this.ipv6Cache;
    }
    const s = socket.constructTCPSocketInstance();
    let ok = false;
    try {
      await s.bind({ address: '::', port: 0, family: 2 });
      await s.connect({
        address: { address: IPV6_PROBE_HOST, port: IPV6_PROBE_PORT, family: 2 },
        timeout: IPV6_PROBE_TIMEOUT_MS
      });
      ok = true;
    } catch (err) {
      ok = false;
    } finally {
      try {
        s.close();
      } catch (e) {
      }
    }
    this.ipv6Cache = ok;
    this.ipv6CacheAt = Date.now();
    return ok;
  }

  async detectNat64Prefix(force: boolean = false): Promise<string> {
    const now = Date.now();
    if (!force && this.nat64Cache !== null && now - this.nat64CacheAt < DETECT_CACHE_TTL_MS) {
      return this.nat64Cache;
    }
    let prefix = '';
    try {
      const netHandle = await connection.getDefaultNet();
      if (netHandle) {
        const addrs = await netHandle.getAddressesByName('ipv4only.arpa');
        for (const a of addrs) {
          const ip = a.address;
          if (ip.indexOf(':') < 0) {
            continue;
          }
          const g = expandPrefixGroups(ip);
          if (g !== null && g[6] === 0xc000 && (g[7] === 0x00aa || g[7] === 0x00ab)) {
            const parts: string[] = [];
            for (let i = 0; i < 6; i++) {
              parts.push(g[i].toString(16));
            }
            prefix = parts.join(':') + '::';
            break;
          }
        }
      }
    } catch (err) {
    }
    this.nat64Cache = prefix;
    this.nat64CacheAt = Date.now();
    return prefix;
  }
}

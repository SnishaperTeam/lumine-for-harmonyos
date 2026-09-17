export interface Policy {
  reply_first?: boolean;
  sniff_override?: string;
  dns_mode?: string;
  dns_cache_ttl?: string;
  connect_timeout?: string;
  tls13_only?: boolean;
  http_status?: number;
  mode?: string;
  minor_ver?: number;
  num_records?: number;
  num_segs?: number;
  wait_for_ack?: boolean;
  send_interval?: string;
  oob?: boolean;
  oob_ex?: boolean;
  fake_ttl?: number;
  fake_sleep?: string;
  attempts?: number;
  max_ttl?: number;
  single_timeout?: string;
  ttl_cache_ttl?: string;
  host?: string;
  map_to?: string;
  nat64_prefix?: string;
}

export interface DnsConfig {
  type: string;
  addr: string;
  resolvers?: string[];
  client_timeout: string;
  wait_timeout: string;
  min_rtt: string;
  udp_size: number;
  singleflight: boolean;
  disable_cache: boolean;
  cache_capacity: number;
  edns0_subnet: string;
  doh_socks5_addr: string;
}

export interface TtlProbingConfig {
  fake_ttl_rules: string;
  singleflight: boolean;
  disable_cache: boolean;
  cache_capacity: number;
}

export interface IPPool {
  ips?: string[];
  port?: number;
  wait_scan_on_startup?: boolean;
  fallback_ip?: string;
  top_ip_count?: number;
  max_concurrency?: number;
  timeout?: string;
  update_interval?: string;
  attempts?: number;
}

export interface OutboundBinding {
  enable_for_android?: boolean;
  method?: string;
  manual_select?: boolean;
  zone?: string;
  preferred_prefix?: string;
  update_interval?: string;
  dial_tcp?: boolean;
  dial_ipv4_target?: string;
  dial_ipv6_target?: string;
  dial_timeout?: string;
  custom_ipv4?: string;
  custom_ipv6?: string;
  custom_zone?: string;
}

export interface LumineConfig {
  log_level: string;
  log_output?: string;
  socks5_address: string;
  http_address: string;
  outbound_binding?: OutboundBinding;
  dns: DnsConfig;
  ttl_probing: TtlProbingConfig;
  fake_ttl_rules?: string;
  dns_singleflight?: boolean;
  dns_cache_ttl?: number;
  dns_cache_cap?: number;
  ttl_singleflight?: boolean;
  ttl_cache_ttl?: number;
  ttl_cache_cap?: number;
  ip_pools?: Record<string, IPPool>;
  hosts?: Record<string, string>;
  default_policy: Policy;
  ip_policies: Record<string, Policy>;
  domain_policies: Record<string, Policy>;
}

export function defaultDnsConfig(): DnsConfig {
  return {
    type: 'https',
    addr: 'https://xwfpeb16ii.cloudflare-gateway.com/dns-query',
    client_timeout: '5s',
    wait_timeout: '400ms',
    min_rtt: '',
    udp_size: 4096,
    singleflight: false,
    disable_cache: false,
    cache_capacity: 4096,
    edns0_subnet: '',
    doh_socks5_addr: ''
  };
}

export function defaultTtlProbingConfig(): TtlProbingConfig {
  return {
    fake_ttl_rules: '0-1;3=3;5-1;8-2;13-3;20=18',
    singleflight: false,
    disable_cache: false,
    cache_capacity: 1024
  };
}

export function defaultPolicy(): Policy {
  return {};
}

export function defaultLumineConfig(): LumineConfig {
  return {
    log_level: 'INFO',
    socks5_address: '127.0.0.1:1080',
    http_address: '127.0.0.1:1225',
    dns: defaultDnsConfig(),
    ttl_probing: defaultTtlProbingConfig(),
    default_policy: defaultPolicy(),
    ip_policies: {},
    domain_policies: {}
  };
}

function isRecord(value: Object | undefined | null): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
}

function asRecord(value: Object | undefined): Record<string, Object> | null {
  if (!isRecord(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

function readString(source: Record<string, Object>, key: string, fallback: string): string {
  const value = source[key];
  return typeof value === 'string' ? value as string : fallback;
}

function readOptionalString(source: Record<string, Object>, key: string): string | undefined {
  const value = source[key];
  if (typeof value === 'string' && (value as string).length > 0) {
    return value as string;
  }
  return undefined;
}

function readBool(source: Record<string, Object>, key: string, fallback: boolean): boolean {
  const value = source[key];
  return typeof value === 'boolean' ? value as boolean : fallback;
}

function readOptionalBool(source: Record<string, Object>, key: string): boolean | undefined {
  const value = source[key];
  return typeof value === 'boolean' ? value as boolean : undefined;
}

function readNumber(source: Record<string, Object>, key: string, fallback: number): number {
  const value = source[key];
  if (typeof value === 'number' && Number.isFinite(value as number)) {
    return value as number;
  }
  return fallback;
}

function readOptionalNumber(source: Record<string, Object>, key: string): number | undefined {
  const value = source[key];
  if (typeof value === 'number' && Number.isFinite(value as number)) {
    return value as number;
  }
  return undefined;
}

function readStringArray(source: Record<string, Object>, key: string): string[] | undefined {
  const value = source[key];
  if (!Array.isArray(value)) {
    return undefined;
  }
  const out: string[] = [];
  for (const item of value as Object[]) {
    if (typeof item === 'string' && (item as string).length > 0) {
      out.push(item as string);
    }
  }
  return out.length > 0 ? out : undefined;
}

function normalizePolicy(value: Object | undefined): Policy {
  const source = asRecord(value);
  if (source === null) {
    return {};
  }
  const policy: Policy = {};
  const replyFirst = readOptionalBool(source, 'reply_first');
  if (replyFirst !== undefined) policy.reply_first = replyFirst;
  const sniffOverride = readOptionalString(source, 'sniff_override');
  if (sniffOverride !== undefined) policy.sniff_override = sniffOverride;
  const dnsMode = readOptionalString(source, 'dns_mode');
  if (dnsMode !== undefined) policy.dns_mode = dnsMode;
  const dnsCacheTtl = readOptionalString(source, 'dns_cache_ttl');
  if (dnsCacheTtl !== undefined) policy.dns_cache_ttl = dnsCacheTtl;
  const connectTimeout = readOptionalString(source, 'connect_timeout');
  if (connectTimeout !== undefined) policy.connect_timeout = connectTimeout;
  const tls13Only = readOptionalBool(source, 'tls13_only');
  if (tls13Only !== undefined) policy.tls13_only = tls13Only;
  const httpStatus = readOptionalNumber(source, 'http_status');
  if (httpStatus !== undefined) policy.http_status = httpStatus;
  const mode = readOptionalString(source, 'mode');
  if (mode !== undefined) policy.mode = mode;
  const minorVer = readOptionalNumber(source, 'minor_ver');
  if (minorVer !== undefined) policy.minor_ver = minorVer;
  const numRecords = readOptionalNumber(source, 'num_records');
  if (numRecords !== undefined) policy.num_records = numRecords;
  const numSegs = readOptionalNumber(source, 'num_segs');
  if (numSegs !== undefined) policy.num_segs = numSegs;
  const waitForAck = readOptionalBool(source, 'wait_for_ack');
  if (waitForAck !== undefined) policy.wait_for_ack = waitForAck;
  const sendInterval = readOptionalString(source, 'send_interval');
  if (sendInterval !== undefined) policy.send_interval = sendInterval;
  const oob = readOptionalBool(source, 'oob');
  if (oob !== undefined) policy.oob = oob;
  const oobEx = readOptionalBool(source, 'oob_ex');
  if (oobEx !== undefined) policy.oob_ex = oobEx;
  const fakeTtl = readOptionalNumber(source, 'fake_ttl');
  if (fakeTtl !== undefined) policy.fake_ttl = fakeTtl;
  const fakeSleep = readOptionalString(source, 'fake_sleep');
  if (fakeSleep !== undefined) policy.fake_sleep = fakeSleep;
  const attempts = readOptionalNumber(source, 'attempts');
  if (attempts !== undefined) policy.attempts = attempts;
  const maxTtl = readOptionalNumber(source, 'max_ttl');
  if (maxTtl !== undefined) policy.max_ttl = maxTtl;
  const singleTimeout = readOptionalString(source, 'single_timeout');
  if (singleTimeout !== undefined) policy.single_timeout = singleTimeout;
  const ttlCacheTtl = readOptionalString(source, 'ttl_cache_ttl');
  if (ttlCacheTtl !== undefined) policy.ttl_cache_ttl = ttlCacheTtl;
  const host = readOptionalString(source, 'host');
  if (host !== undefined) policy.host = host;
  const mapTo = readOptionalString(source, 'map_to');
  if (mapTo !== undefined) policy.map_to = mapTo;
  const nat64Prefix = readOptionalString(source, 'nat64_prefix');
  if (nat64Prefix !== undefined) policy.nat64_prefix = nat64Prefix;
  return policy;
}

function normalizePolicyMap(value: Object | undefined): Record<string, Policy> {
  const out: Record<string, Policy> = {};
  if (!isRecord(value)) {
    return out;
  }
  const source = value as Record<string, Object>;
  for (const key of Object.keys(source)) {
    if (key.length === 0) {
      continue;
    }
    out[key] = normalizePolicy(source[key]);
  }
  return out;
}

function normalizeHostMap(value: Object | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!isRecord(value)) {
    return out;
  }
  const source = value as Record<string, Object>;
  for (const key of Object.keys(source)) {
    const item = source[key];
    if (key.length > 0 && typeof item === 'string') {
      out[key] = item as string;
    }
  }
  return out;
}

function normalizeDns(value: Object | undefined): DnsConfig {
  const source = asRecord(value);
  if (source === null) {
    return defaultDnsConfig();
  }
  const base = defaultDnsConfig();
  const dns: DnsConfig = {
    type: readString(source, 'type', base.type),
    addr: readString(source, 'addr', base.addr),
    client_timeout: readString(source, 'client_timeout', base.client_timeout),
    wait_timeout: readString(source, 'wait_timeout', base.wait_timeout),
    min_rtt: readString(source, 'min_rtt', base.min_rtt),
    udp_size: readNumber(source, 'udp_size', base.udp_size),
    singleflight: readBool(source, 'singleflight', base.singleflight),
    disable_cache: readBool(source, 'disable_cache', base.disable_cache),
    cache_capacity: readNumber(source, 'cache_capacity', base.cache_capacity),
    edns0_subnet: readString(source, 'edns0_subnet', base.edns0_subnet),
    doh_socks5_addr: readString(source, 'doh_socks5_addr', base.doh_socks5_addr)
  };
  const resolvers = readStringArray(source, 'resolvers');
  if (resolvers !== undefined) {
    dns.resolvers = resolvers;
  }
  if (dns.addr.length === 0) {
    dns.addr = base.addr;
  }
  if (dns.type.length === 0) {
    dns.type = base.type;
  }
  return dns;
}

function normalizeTtlProbing(value: Object | undefined): TtlProbingConfig {
  const source = asRecord(value);
  if (source === null) {
    return defaultTtlProbingConfig();
  }
  const base = defaultTtlProbingConfig();
  return {
    fake_ttl_rules: readString(source, 'fake_ttl_rules', base.fake_ttl_rules),
    singleflight: readBool(source, 'singleflight', base.singleflight),
    disable_cache: readBool(source, 'disable_cache', base.disable_cache),
    cache_capacity: readNumber(source, 'cache_capacity', base.cache_capacity)
  };
}

function normalizeOutboundBinding(value: Object | undefined): OutboundBinding | undefined {
  const source = asRecord(value);
  if (source === null) {
    return undefined;
  }
  const binding: OutboundBinding = {};
  const enableForAndroid = readOptionalBool(source, 'enable_for_android');
  if (enableForAndroid !== undefined) binding.enable_for_android = enableForAndroid;
  const method = readOptionalString(source, 'method');
  if (method !== undefined) binding.method = method;
  const manualSelect = readOptionalBool(source, 'manual_select');
  if (manualSelect !== undefined) binding.manual_select = manualSelect;
  const zone = readOptionalString(source, 'zone');
  if (zone !== undefined) binding.zone = zone;
  const preferredPrefix = readOptionalString(source, 'preferred_prefix');
  if (preferredPrefix !== undefined) binding.preferred_prefix = preferredPrefix;
  const updateInterval = readOptionalString(source, 'update_interval');
  if (updateInterval !== undefined) binding.update_interval = updateInterval;
  const dialTcp = readOptionalBool(source, 'dial_tcp');
  if (dialTcp !== undefined) binding.dial_tcp = dialTcp;
  const dialV4 = readOptionalString(source, 'dial_ipv4_target');
  if (dialV4 !== undefined) binding.dial_ipv4_target = dialV4;
  const dialV6 = readOptionalString(source, 'dial_ipv6_target');
  if (dialV6 !== undefined) binding.dial_ipv6_target = dialV6;
  const dialTimeout = readOptionalString(source, 'dial_timeout');
  if (dialTimeout !== undefined) binding.dial_timeout = dialTimeout;
  const customV4 = readOptionalString(source, 'custom_ipv4');
  if (customV4 !== undefined) binding.custom_ipv4 = customV4;
  const customV6 = readOptionalString(source, 'custom_ipv6');
  if (customV6 !== undefined) binding.custom_ipv6 = customV6;
  const customZone = readOptionalString(source, 'custom_zone');
  if (customZone !== undefined) binding.custom_zone = customZone;
  return binding;
}

function normalizePools(value: Object | undefined): Record<string, IPPool> | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const source = value as Record<string, Object>;
  const out: Record<string, IPPool> = {};
  for (const key of Object.keys(source)) {
    const entry = asRecord(source[key]);
    if (key.length === 0 || entry === null) {
      continue;
    }
    const pool: IPPool = {};
    const ips = readStringArray(entry, 'ips');
    if (ips !== undefined) pool.ips = ips;
    const port = readOptionalNumber(entry, 'port');
    if (port !== undefined) pool.port = port;
    const waitScan = readOptionalBool(entry, 'wait_scan_on_startup');
    if (waitScan !== undefined) pool.wait_scan_on_startup = waitScan;
    const fallbackIp = readOptionalString(entry, 'fallback_ip');
    if (fallbackIp !== undefined) pool.fallback_ip = fallbackIp;
    const topIpCount = readOptionalNumber(entry, 'top_ip_count');
    if (topIpCount !== undefined) pool.top_ip_count = topIpCount;
    const maxConcurrency = readOptionalNumber(entry, 'max_concurrency');
    if (maxConcurrency !== undefined) pool.max_concurrency = maxConcurrency;
    const timeout = readOptionalString(entry, 'timeout');
    if (timeout !== undefined) pool.timeout = timeout;
    const updateInterval = readOptionalString(entry, 'update_interval');
    if (updateInterval !== undefined) pool.update_interval = updateInterval;
    const attempts = readOptionalNumber(entry, 'attempts');
    if (attempts !== undefined) pool.attempts = attempts;
    out[key] = pool;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

export function parseLumineConfig(json: string): LumineConfig {
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(json) as Object;
  } catch (err) {
    throw new Error('配置不是合法的 JSON');
  }
  if (!isRecord(parsed)) {
    throw new Error('配置根节点必须是 JSON 对象');
  }
  const source = parsed as Record<string, Object>;
  const config: LumineConfig = {
    log_level: readString(source, 'log_level', 'INFO'),
    socks5_address: readString(source, 'socks5_address', ''),
    http_address: readString(source, 'http_address', ''),
    dns: normalizeDns(source['dns']),
    ttl_probing: normalizeTtlProbing(source['ttl_probing']),
    default_policy: normalizePolicy(source['default_policy']),
    ip_policies: normalizePolicyMap(source['ip_policies']),
    domain_policies: normalizePolicyMap(source['domain_policies'])
  };
  const logOutput = readOptionalString(source, 'log_output');
  if (logOutput !== undefined) config.log_output = logOutput;
  const outbound = normalizeOutboundBinding(source['outbound_binding']);
  if (outbound !== undefined) config.outbound_binding = outbound;
  const fakeTtlRules = readOptionalString(source, 'fake_ttl_rules');
  if (fakeTtlRules !== undefined) config.fake_ttl_rules = fakeTtlRules;
  const dnsSingleflight = readOptionalBool(source, 'dns_singleflight');
  if (dnsSingleflight !== undefined) config.dns_singleflight = dnsSingleflight;
  const dnsCacheTtl = readOptionalNumber(source, 'dns_cache_ttl');
  if (dnsCacheTtl !== undefined) config.dns_cache_ttl = dnsCacheTtl;
  const dnsCacheCap = readOptionalNumber(source, 'dns_cache_cap');
  if (dnsCacheCap !== undefined) config.dns_cache_cap = dnsCacheCap;
  const ttlSingleflight = readOptionalBool(source, 'ttl_singleflight');
  if (ttlSingleflight !== undefined) config.ttl_singleflight = ttlSingleflight;
  const ttlCacheTtl = readOptionalNumber(source, 'ttl_cache_ttl');
  if (ttlCacheTtl !== undefined) config.ttl_cache_ttl = ttlCacheTtl;
  const ttlCacheCap = readOptionalNumber(source, 'ttl_cache_cap');
  if (ttlCacheCap !== undefined) config.ttl_cache_cap = ttlCacheCap;
  const hosts = normalizeHostMap(source['hosts']);
  if (Object.keys(hosts).length > 0) config.hosts = hosts;
  const pools = normalizePools(source['ip_pools']);
  if (pools !== undefined) config.ip_pools = pools;
  if (config.socks5_address.length === 0) {
    config.socks5_address = '127.0.0.1:1080';
  }
  if (config.http_address.length === 0) {
    config.http_address = '127.0.0.1:1225';
  }
  return config;
}

export function serializeLumineConfig(config: LumineConfig): string {
  return JSON.stringify(config);
}

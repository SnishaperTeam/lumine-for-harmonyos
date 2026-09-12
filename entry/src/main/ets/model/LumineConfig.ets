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

export function parseLumineConfig(json: string): LumineConfig {
  return JSON.parse(json) as LumineConfig;
}

export function serializeLumineConfig(config: LumineConfig): string {
  return JSON.stringify(config);
}

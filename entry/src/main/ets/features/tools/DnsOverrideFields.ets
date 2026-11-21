import { DnsOverrideValue } from '../../client/DnsOverrides';

export type DnsFieldKind = 'toggle' | 'text' | 'number' | 'choice' | 'list' | 'policy';

export class DnsOverrideField {
  readonly key: string;
  readonly label: ResourceStr;
  readonly kind: DnsFieldKind;
  readonly initial: DnsOverrideValue;
  readonly choices: string[];

  constructor(key: string, label: ResourceStr, kind: DnsFieldKind, initial: DnsOverrideValue, choices: string[] = []) {
    this.key = key;
    this.label = label;
    this.kind = kind;
    this.initial = initial;
    this.choices = choices;
  }
}

export class DnsOverrideSection {
  readonly title: ResourceStr;
  readonly fields: DnsOverrideField[];

  constructor(title: ResourceStr, fields: DnsOverrideField[]) {
    this.title = title;
    this.fields = fields;
  }
}

export const DNS_OVERRIDE_SECTIONS: DnsOverrideSection[] = [
  new DnsOverrideSection($r('app.string.network_options'), [
    new DnsOverrideField('listen', $r('app.string.dns_override_listen'), 'text', ''),
    new DnsOverrideField('use-hosts', $r('app.string.dns_override_use_hosts'), 'toggle', true),
    new DnsOverrideField('use-system-hosts', $r('app.string.dns_override_system_hosts'), 'toggle', true),
    new DnsOverrideField('ipv6', 'IPv6', 'toggle', false),
    new DnsOverrideField('ipv6-timeout', $r('app.string.dns_override_ipv6_timeout'), 'number', 100),
    new DnsOverrideField('respect-rules', $r('app.string.dns_override_respect_rules'), 'toggle', false),
    new DnsOverrideField('prefer-h3', 'Prefer H3', 'toggle', false),
    new DnsOverrideField('cache-algorithm', $r('app.string.dns_override_cache_algorithm'), 'choice', 'lru', ['lru', 'arc']),
    new DnsOverrideField('cache-max-size', $r('app.string.dns_override_cache_size'), 'number', 4096),
    new DnsOverrideField('enhanced-mode', $r('app.string.dns_override_mode'), 'choice', 'redir-host',
      ['normal', 'fake-ip', 'redir-host'])
  ]),
  new DnsOverrideSection('Fake-IP', [
    new DnsOverrideField('fake-ip-range', $r('app.string.dns_override_fake_range'), 'text', '198.18.0.1/16'),
    new DnsOverrideField('fake-ip-range6', $r('app.string.dns_override_fake_range6'), 'text', ''),
    new DnsOverrideField('fake-ip-filter', $r('app.string.dns_override_fake_ip_filter'), 'list',
      ['dns.msftnsci.com', 'www.msftnsci.com', 'www.msftconnecttest.com']),
    new DnsOverrideField('fake-ip-filter-mode', $r('app.string.dns_override_fake_ip_mode'), 'choice', 'blacklist',
      ['blacklist', 'whitelist', 'rule']),
    new DnsOverrideField('fake-ip-ttl', 'Fake-IP TTL', 'number', 1)
  ]),
  new DnsOverrideSection('Nameserver', [
    new DnsOverrideField('default-nameserver', 'Default Nameserver', 'list', ['114.114.114.114', '223.5.5.5', '8.8.8.8', '1.0.0.1']),
    new DnsOverrideField('nameserver-policy', 'Nameserver Policy', 'policy', []),
    new DnsOverrideField('nameserver', 'Nameserver', 'list', ['https://doh.pub/dns-query', 'tls://223.5.5.5:853']),
    new DnsOverrideField('fallback', 'Fallback', 'list', []),
    new DnsOverrideField('fallback-lazy-query', $r('app.string.dns_override_fallback_lazy'), 'toggle', false),
    new DnsOverrideField('proxy-server-nameserver', 'Proxy Server Nameserver', 'list', []),
    new DnsOverrideField('proxy-server-nameserver-policy', 'Proxy Server Nameserver Policy', 'policy', []),
    new DnsOverrideField('direct-nameserver', 'Direct Nameserver', 'list', []),
    new DnsOverrideField('direct-nameserver-follow-policy', $r('app.string.dns_override_direct_policy'), 'toggle', false)
  ]),
  new DnsOverrideSection($r('app.string.dns_override_fallback_filter'), [
    new DnsOverrideField('fallback-filter.geoip', 'GeoIP', 'toggle', true),
    new DnsOverrideField('fallback-filter.geoip-code', 'GeoIP Code', 'text', 'CN'),
    new DnsOverrideField('fallback-filter.geosite', 'GeoSite', 'list', []),
    new DnsOverrideField('fallback-filter.ipcidr', 'IP-CIDR', 'list', []),
    new DnsOverrideField('fallback-filter.domain', $r('app.string.dns_override_domain'), 'list', [])
  ])
];

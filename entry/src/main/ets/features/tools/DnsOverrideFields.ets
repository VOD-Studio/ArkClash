import { DnsOverrideValue } from '../../client/DnsOverrides';

export type DnsFieldKind = 'toggle' | 'text' | 'choice' | 'list';

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
    new DnsOverrideField('ipv6', 'IPv6', 'toggle', false),
    new DnsOverrideField('prefer-h3', 'Prefer H3', 'toggle', false),
    new DnsOverrideField('enhanced-mode', $r('app.string.dns_override_mode'), 'choice', 'redir-host',
      ['normal', 'fake-ip', 'redir-host'])
  ]),
  new DnsOverrideSection('Fake-IP', [
    new DnsOverrideField('fake-ip-filter', $r('app.string.dns_override_fake_ip_filter'), 'list',
      ['dns.msftnsci.com', 'www.msftnsci.com', 'www.msftconnecttest.com']),
    new DnsOverrideField('fake-ip-filter-mode', $r('app.string.dns_override_fake_ip_mode'), 'choice', 'blacklist',
      ['blacklist', 'whitelist', 'rule'])
  ]),
  new DnsOverrideSection('Nameserver', [
    new DnsOverrideField('default-nameserver', 'Default Nameserver', 'list', ['114.114.114.114', '223.5.5.5', '8.8.8.8', '1.0.0.1']),
    new DnsOverrideField('nameserver', 'Nameserver', 'list', ['https://doh.pub/dns-query', 'tls://223.5.5.5:853']),
    new DnsOverrideField('fallback', 'Fallback', 'list', []),
    new DnsOverrideField('proxy-server-nameserver', 'Proxy Server Nameserver', 'list', []),
    new DnsOverrideField('direct-nameserver', 'Direct Nameserver', 'list', [])
  ])
];

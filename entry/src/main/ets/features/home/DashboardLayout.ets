export const DEFAULT_DASHBOARD_CARDS: string[] = ['status', 'speed', 'mode', 'profile', 'groups'];
export const LEGACY_DASHBOARD_CARDS: string[] = ['status', 'speed', 'mode', 'lan', 'services', 'profile', 'groups',
  'connections', 'memory'];
export const DASHBOARD_CARDS: string[] = ['status', 'speed', 'mode', 'vpn', 'services', 'profile', 'groups',
  'connections', 'lan', 'memory'];

const CARD_NAMES: Record<string, string> = {
  'currentOutbound': 'status', 'networkSpeed': 'speed', 'outboundMode': 'mode', 'outboundModeV2': 'mode',
  'profiles': 'profile', 'proxyGroups': 'groups', 'vpnButton': 'vpn', 'serviceStatus': 'services',
  'connectionStats': 'connections', 'intranetIp': 'lan', 'memoryInfo': 'memory',
  'connections': 'connections', 'requests': 'connections', 'dnsQueries': 'connections',
  'trafficUsage': 'speed', 'networkDetection': 'lan'
};

export function dashboardCards(stored: string[]): string[] {
  const cards: string[] = [];
  for (const name of stored) {
    const id = CARD_NAMES[name] ?? name;
    if (DASHBOARD_CARDS.includes(id) && !cards.includes(id)) {
      cards.push(id);
    }
  }
  if (!cards.includes('status')) {
    cards.unshift('status');
  }
  return cards;
}

export function movedDashboardCards(cards: string[], from: number, to: number): string[] {
  if (from < 0 || from >= cards.length || to < 0 || to >= cards.length) {
    return cards.slice();
  }
  const changed = cards.slice();
  const moved = changed.splice(from, 1)[0];
  changed.splice(to, 0, moved);
  return changed;
}

export function dashboardCardTitle(id: string): ResourceStr {
  switch (id) {
    case 'status': return $r('app.string.card_status');
    case 'speed': return $r('app.string.card_speed');
    case 'mode': return $r('app.string.card_mode');
    case 'profile': return $r('app.string.card_profile');
    case 'groups': return $r('app.string.card_group');
    case 'vpn': return $r('app.string.dash_vpn');
    case 'services': return $r('app.string.card_services');
    case 'connections': return $r('app.string.card_conn_stats');
    case 'lan': return $r('app.string.card_lan_ip');
    case 'memory': return $r('app.string.card_memory');
    default: return id;
  }
}

export function dashboardCardGlyph(id: string): string {
  switch (id) {
    case 'status': return 'status';
    case 'speed': return 'speed';
    case 'mode': return 'split';
    case 'profile': return 'profiles';
    case 'groups': return 'layers';
    case 'vpn': return 'vpn';
    case 'services': return 'verified';
    case 'connections': return 'connections';
    case 'lan': return 'devices';
    default: return 'memory';
  }
}

export function dashboardCardDescription(id: string): ResourceStr {
  switch (id) {
    case 'status': return $r('app.string.dash_card_description_status');
    case 'connections': return $r('app.string.dash_card_description_connections');
    case 'memory': return $r('app.string.dash_card_description_memory');
    default: return '';
  }
}

const DASHBOARD_CARD_SEEDS: Record<string, number> = { 'status': 0, 'speed': 1, 'mode': 2, 'vpn': 3, 'services': 5,
  'profile': 6, 'groups': 7, 'connections': 8, 'lan': 9, 'memory': 10 };

export function dashboardCardMotionSeed(id: string): number {
  return DASHBOARD_CARD_SEEDS[id] ?? 0;
}

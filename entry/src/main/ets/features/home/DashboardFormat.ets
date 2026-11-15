export interface DashboardTrafficValue {
  amount: string;
  unit: string;
}

const DASHBOARD_TRAFFIC_UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
const DASHBOARD_COUNT_UNITS: string[] = ['', 'K', 'M', 'B', 'T'];

export function dashboardTrafficValue(bytes: number): DashboardTrafficValue {
  let amount = bytes;
  let unit = 0;
  while (amount >= 1024 && unit < DASHBOARD_TRAFFIC_UNITS.length - 1) {
    amount /= 1024;
    unit++;
  }
  const fixed = amount.toFixed(1);
  return { amount: fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed,
    unit: DASHBOARD_TRAFFIC_UNITS[unit] };
}

export function dashboardTraffic(bytes: number): string {
  const show = dashboardTrafficValue(bytes);
  return `${show.amount} ${show.unit}`;
}

export function dashboardCount(count: number): string {
  if (count < 0) { return '—'; }
  if (count < 100000) {
    const digits = Math.floor(count).toString();
    let grouped = '';
    for (let i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 === 0) { grouped += ','; }
      grouped += digits.charAt(i);
    }
    return grouped;
  }
  let amount = count;
  let unit = 0;
  while (amount >= 1000 && unit < DASHBOARD_COUNT_UNITS.length - 1) {
    amount /= 1000;
    unit++;
  }
  let decimals = Math.max(0, 2 - Math.floor(Math.log10(amount)));
  let fixed = amount.toFixed(decimals);
  if (Number(fixed) >= 1000 && unit < DASHBOARD_COUNT_UNITS.length - 1) {
    amount /= 1000;
    unit++;
    decimals = Math.max(0, 2 - Math.floor(Math.log10(amount)));
    fixed = amount.toFixed(decimals);
  }
  while (fixed.includes('.') && fixed.endsWith('0')) { fixed = fixed.substring(0, fixed.length - 1); }
  if (fixed.endsWith('.')) { fixed = fixed.substring(0, fixed.length - 1); }
  return `${fixed}${DASHBOARD_COUNT_UNITS[unit]}`;
}

export function dashboardUpdatedAgo(updatedAt: number, clock: number): ResourceStr {
  if (updatedAt <= 0) { return '—'; }
  const minutes = Math.floor((clock - updatedAt) / 60000);
  const days = Math.floor(minutes / 1440);
  if (days >= 365) { return $r('app.string.dash_updated_years', Math.floor(days / 365)); }
  if (days >= 30) { return $r('app.string.dash_updated_months', Math.floor(days / 30)); }
  if (days >= 1) { return $r('app.string.dash_updated_days', days); }
  if (minutes >= 60) { return $r('app.string.dash_updated_hours', Math.floor(minutes / 60)); }
  if (minutes >= 1) { return $r('app.string.dash_updated_minutes', minutes); }
  return $r('app.string.dash_updated_just_now');
}

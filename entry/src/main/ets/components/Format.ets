const UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];

/** 1024 进制；小于 10 的数保留两位小数，其余一位，宽度大致稳定。 */
export function formatBytes(bytes: number): string {
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit === 0) {
    return `${Math.round(value)} B`;
  }
  return `${value.toFixed(value < 10 ? 2 : 1)} ${UNITS[unit]}`;
}

/** 拆成数值和单位，大号数字配小号单位时用。 */
export function splitBytes(bytes: number): string[] {
  const text = formatBytes(bytes);
  const space = text.lastIndexOf(' ');
  return [text.substring(0, space), text.substring(space + 1)];
}

export function formatSpeed(bytesPerSecond: number): string {
  return `${formatBytes(bytesPerSecond)}/s`;
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** 本地时区的 YYYY-MM-DD。 */
export function formatDate(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 本地时区的 MM-DD HH:mm。 */
export function formatDateTime(ms: number): string {
  const d = new Date(ms);
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

import { TrafficSample, HISTORY_SIZE } from '../../client/Traffic';
export function dashboardTrafficPath(samples: TrafficSample[], upload: boolean, chartWidth: number,
  chartHeight: number): string {
  if (samples.length === 0 || chartWidth <= 0) {
    return '';
  }
  let maximum = 16 * 1024;
  for (const sample of samples) {
    if (sample.available) {
      maximum = Math.max(maximum, sample.up, sample.down);
    }
  }
  const newest = samples[samples.length - 1].timestamp;
  const oldest = newest - (HISTORY_SIZE - 1) * 1000;
  let drawing = false;
  let commands = '';
  for (const sample of samples) {
    if (!sample.available) {
      drawing = false;
      continue;
    }
    const x = Math.max(0, sample.timestamp - oldest) / ((HISTORY_SIZE - 1) * 1000) * chartWidth;
    const y = 1 + (chartHeight - 2) * (1 - (upload ? sample.up : sample.down) / maximum);
    commands += `${drawing ? 'L' : 'M'}${x.toFixed(2)} ${y.toFixed(2)} `;
    drawing = true;
  }
  return commands;
}

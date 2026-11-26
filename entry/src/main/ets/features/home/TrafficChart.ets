import { TrafficSample, HISTORY_SIZE } from '../../client/Traffic';

export interface DashboardTrafficGraph {
  line: string;
  area: string;
}

const DASHBOARD_TRAFFIC_KERNEL: number[] = [1, Math.exp(-1 / 4.5), Math.exp(-4 / 4.5),
  Math.exp(-9 / 4.5), Math.exp(-16 / 4.5)];

function dashboardCurveHeight(first: number, control0: number, control1: number, last: number,
  position: number): number {
  const inverse = 1 - position;
  return inverse * inverse * inverse * first + 3 * inverse * inverse * position * control0 +
    3 * inverse * position * position * control1 + position * position * position * last;
}

function dashboardCurvePeak(first: number, control0: number, control1: number, last: number): number {
  let maximum = Math.max(first, last);
  const a = -first + 3 * control0 - 3 * control1 + last;
  const b = 2 * first - 4 * control0 + 2 * control1;
  const c = -first + control0;
  if (Math.abs(a) < 0.000001) {
    const position = b === 0 ? -1 : -c / b;
    if (position > 0 && position < 1) {
      maximum = Math.max(maximum, dashboardCurveHeight(first, control0, control1, last, position));
    }
    return maximum;
  }
  const discriminant = b * b - 4 * a * c;
  if (discriminant >= 0) {
    const root = Math.sqrt(discriminant);
    const firstPosition = (-b + root) / (2 * a);
    const secondPosition = (-b - root) / (2 * a);
    if (firstPosition > 0 && firstPosition < 1) {
      maximum = Math.max(maximum, dashboardCurveHeight(first, control0, control1, last, firstPosition));
    }
    if (secondPosition > 0 && secondPosition < 1) {
      maximum = Math.max(maximum, dashboardCurveHeight(first, control0, control1, last, secondPosition));
    }
  }
  return maximum;
}

export function dashboardTrafficGraph(samples: TrafficSample[], upload: boolean, chartWidth: number,
  chartHeight: number): DashboardTrafficGraph {
  if (samples.length === 0 || chartWidth <= 0 || chartHeight <= 0) {
    return { line: '', area: '' };
  }
  const heights: number[] = new Array<number>(samples.length).fill(0);
  const slopes: number[] = new Array<number>(samples.length).fill(0);
  let maximum = 8 * 1024;
  let start = 0;
  while (start < samples.length) {
    if (!samples[start].available) {
      start++;
      continue;
    }
    let end = start;
    while (end + 1 < samples.length && samples[end + 1].available) {
      end++;
    }
    for (let i = start; i <= end; i++) {
      let sum = 0;
      let weight = 0;
      for (let j = Math.max(start, i - 4); j <= Math.min(end, i + 4); j++) {
        const currentWeight = DASHBOARD_TRAFFIC_KERNEL[Math.abs(j - i)];
        sum += currentWeight * (upload ? samples[j].up : samples[j].down);
        weight += currentWeight;
      }
      heights[i] = sum / weight;
      maximum = Math.max(maximum, heights[i]);
    }
    for (let i = start + 1; i < end; i++) {
      slopes[i] = Math.max(-3 * heights[i], Math.min(3 * heights[i], (heights[i + 1] - heights[i - 1]) / 2));
    }
    for (let i = start + 1; i <= end; i++) {
      maximum = Math.max(maximum, dashboardCurvePeak(heights[i - 1], heights[i - 1] + slopes[i - 1] / 3,
        heights[i] - slopes[i] / 3, heights[i]));
    }
    start = end + 1;
  }
  const oldest = samples[samples.length - 1].timestamp - (HISTORY_SIZE - 1) * 1000;
  // 为 0 B/s 基线预留底部内边距，避免折线紧贴容器底边被圆角裁切后显得断断续续。
  const baselinePad = Math.min(6, Math.max(2, chartHeight * 0.04));
  const baseline = Math.max(0, chartHeight - baselinePad);
  const yScale = Math.max(0, baseline - 2) / maximum;
  let line = '';
  let area = '';
  let segmentArea = '';
  let segmentPoints = 0;
  let drawing = false;
  let previousX = 0;
  let previousY = 0;
  for (let i = 0; i < samples.length; i++) {
    if (!samples[i].available) {
      if (drawing && segmentPoints >= 2) { area += `${segmentArea}L${previousX.toFixed(3)} ${chartHeight} Z `; }
      drawing = false;
      segmentArea = '';
      segmentPoints = 0;
      continue;
    }
    const x = Math.max(0, samples[i].timestamp - oldest) / ((HISTORY_SIZE - 1) * 1000) * chartWidth;
    const y = baseline - heights[i] * yScale;
    if (!drawing) {
      line += `M${x.toFixed(3)} ${y.toFixed(3)} `;
      segmentArea = `M${x.toFixed(3)} ${chartHeight} L${x.toFixed(3)} ${y.toFixed(3)} `;
      segmentPoints = 1;
    } else {
      const third = (x - previousX) / 3;
      const curve = `C${(previousX + third).toFixed(3)} ${(previousY - slopes[i - 1] * yScale / 3).toFixed(3)} ` +
        `${(x - third).toFixed(3)} ${(y + slopes[i] * yScale / 3).toFixed(3)} ${x.toFixed(3)} ${y.toFixed(3)} `;
      line += curve;
      segmentArea += curve;
      segmentPoints++;
    }
    drawing = true;
    previousX = x;
    previousY = y;
  }
  if (drawing && segmentPoints >= 2) { area += `${segmentArea}L${previousX.toFixed(3)} ${chartHeight} Z`; }
  return { line: line, area: area };
}

export function dashboardTrafficPath(samples: TrafficSample[], upload: boolean, chartWidth: number,
  chartHeight: number): string {
  return dashboardTrafficGraph(samples, upload, chartWidth, chartHeight).line;
}

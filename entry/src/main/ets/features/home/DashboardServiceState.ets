import { ServiceCheckTask, ServiceResult, ServiceTarget } from '../../client/ServiceCheck';
import { RoutedProbeError } from '../../client/RoutedProbe';
import { serviceInfo } from './Services';

const RESULT_TTL_MS = 60000;

@ObservedV2
export class DashboardServiceState {
  @Trace results: Record<string, ServiceResult> = {};
  @Trace busy: boolean = false;
  @Trace busyIds: string[] = [];
  @Trace failed: boolean = false;
  private generation: number = 0;
  private filesDir: string = '';
  private route: string = '';
  private routed: boolean = false;
  private visible: boolean = false;
  private task?: ServiceCheckTask;
  private watchedIds: string[] = [];
  private attempted: Set<string> = new Set<string>();
  private automaticPaused: boolean = false;

  observe(filesDir: string, route: string, routed: boolean, visible: boolean, ids: string[]): void {
    const routeChanged = filesDir !== this.filesDir || route !== this.route || routed !== this.routed;
    const entering = visible && !this.visible;
    const targetsChanged = ids.length !== this.watchedIds.length ||
      ids.some((id: string, index: number): boolean => id !== this.watchedIds[index]);
    if (routeChanged) {
      this.abort();
      this.results = {};
      this.failed = false;
    } else if (targetsChanged && this.busyIds.some((id: string): boolean => !ids.includes(id))) {
      this.abort();
    }
    if (routeChanged || entering) {
      this.automaticPaused = false;
    }
    if (routeChanged || entering || targetsChanged) {
      this.attempted.clear();
      for (const id of this.busyIds) {
        this.attempted.add(id);
      }
    }
    this.filesDir = filesDir;
    this.route = route;
    this.routed = routed;
    this.visible = visible;
    this.watchedIds = ids;
    if (!visible) {
      this.abort();
    } else {
      this.startPending();
    }
  }

  cancel(): void {
    this.automaticPaused = true;
    this.abort();
  }

  private abort(): void {
    this.generation++;
    this.task?.cancel();
    this.task = undefined;
    this.busy = false;
    this.busyIds = [];
  }

  private startPending(): void {
    if (!this.visible || this.busy || this.automaticPaused) {
      return;
    }
    const now = Date.now();
    const pending: string[] = [];
    for (const id of this.watchedIds) {
      const result = this.results[id];
      if (!this.attempted.has(id) &&
        (result === undefined || now < result.checkedAt || now - result.checkedAt >= RESULT_TTL_MS)) {
        pending.push(id);
      }
    }
    if (pending.length > 0) {
      this.run(pending);
    }
  }

  async run(ids: string[]): Promise<void> {
    if (!this.visible || this.busy) {
      return;
    }
    const targets: ServiceTarget[] = [];
    for (const id of ids) {
      this.attempted.add(id);
      const info = serviceInfo(id);
      if (info !== undefined) {
        targets.push({ id: id, url: info.url });
      }
    }
    if (targets.length === 0) {
      return;
    }
    const generation = ++this.generation;
    const task = new ServiceCheckTask();
    this.task = task;
    this.busy = true;
    this.failed = false;
    this.busyIds = targets.map((target: ServiceTarget): string => target.id);
    try {
      const results = await task.run(this.filesDir, targets, this.route, this.routed);
      if (generation !== this.generation || !this.visible) {
        return;
      }
      const merged: Record<string, ServiceResult> = {};
      for (const id of Object.keys(this.results)) {
        merged[id] = this.results[id];
      }
      for (const result of results) {
        merged[result.id] = result;
      }
      this.results = merged;
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
        for (const id of this.watchedIds) {
          this.attempted.add(id);
        }
        if (e instanceof RoutedProbeError && e.reason === 'routeChanged') {
          this.results = {};
        }
      }
    } finally {
      if (generation === this.generation) {
        this.task = undefined;
        this.busy = false;
        this.busyIds = [];
        this.startPending();
      }
    }
  }
}

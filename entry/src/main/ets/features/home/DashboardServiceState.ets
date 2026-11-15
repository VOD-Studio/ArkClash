import { ServiceCheckTask, ServiceResult, ServiceTarget } from '../../client/ServiceCheck';
import { RoutedProbeError } from '../../client/RoutedProbe';
import { serviceInfo } from './Services';

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

  observe(filesDir: string, route: string, routed: boolean, visible: boolean): void {
    if (route !== this.route || routed !== this.routed) {
      this.cancel();
      this.results = {};
      this.failed = false;
    }
    this.filesDir = filesDir;
    this.route = route;
    this.routed = routed;
    this.visible = visible;
    if (!visible) {
      this.cancel();
    }
  }

  cancel(): void {
    this.generation++;
    this.task?.cancel();
    this.task = undefined;
    this.busy = false;
    this.busyIds = [];
  }

  async run(ids: string[]): Promise<void> {
    if (!this.visible || this.busy) {
      return;
    }
    const targets: ServiceTarget[] = [];
    for (const id of ids) {
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
      const merged = JSON.parse(JSON.stringify(this.results)) as Record<string, ServiceResult>;
      for (const result of results) {
        merged[result.id] = result;
      }
      this.results = merged;
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
        if (e instanceof RoutedProbeError && e.reason === 'routeChanged') {
          this.results = {};
        }
      }
    } finally {
      if (generation === this.generation) {
        this.task = undefined;
        this.busy = false;
        this.busyIds = [];
      }
    }
  }
}

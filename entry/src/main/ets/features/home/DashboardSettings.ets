import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { writeTextAsync } from '../../shared/Files';
import { dashboardCards, DEFAULT_DASHBOARD_CARDS, LEGACY_DASHBOARD_CARDS } from './DashboardLayout';
import { decodeServiceSlots, encodeServiceSlots, ServiceSlot } from './Services';

export interface DashboardPatch {
  cards?: string[];
  hideIp?: boolean;
  services?: ServiceSlot[];
}

@ObservedV2
export class DashboardSettings {
  @Trace cards: string[] = DEFAULT_DASHBOARD_CARDS.slice();
  @Trace hideIp: boolean = false;
  @Trace services: ServiceSlot[] = [];
  @Trace revision: number = 0;
  @Trace ready: boolean = false;
  @Trace saving: boolean = false;
  @Trace failure: string = '';
  @Trace hasDraft: boolean = false;
  private path: string = '';
  private loading: boolean = false;
  private document: Record<string, Object> = {};
  private draft?: DashboardPatch;

  async load(context: common.UIAbilityContext): Promise<void> {
    if (this.ready || this.loading) {
      return;
    }
    this.loading = true;
    this.path = `${context.filesDir}/dashboard.json`;
    this.failure = '';
    try {
      if (await fs.access(this.path)) {
        this.apply(this.decode(await fs.readText(this.path)));
      } else {
        const prefs = await preferences.getPreferences(context, { name: 'settings' });
        const legacy = await prefs.getAll() as Record<string, Object>;
        const hasProfiles = await fs.access(`${context.filesDir}/profiles/list.json`);
        const existing = hasProfiles || legacy['serviceLayout'] !== undefined || legacy['dashboardWidgets'] !== undefined ||
          legacy['outboundMode'] !== undefined || legacy['allowLan'] !== undefined ||
          Number(legacy['lastConnectDuration'] ?? 0) > 0;
        const initial = this.migrate(legacy, existing);
        await writeTextAsync(this.path, JSON.stringify(initial));
        this.apply(initial);
      }
      this.ready = true;
    } catch (e) {
      this.failure = 'read';
    } finally {
      this.loading = false;
    }
  }

  async commit(patch: DashboardPatch, expectedRevision: number): Promise<void> {
    if (!this.ready || this.saving) {
      throw new Error('dashboard store busy');
    }
    this.saving = true;
    this.failure = '';
    this.draft = patch;
    this.hasDraft = true;
    const previous = this.document;
    let optimistic = false;
    try {
      const latest = this.decode(await fs.readText(this.path));
      if (Number(latest['revision']) !== expectedRevision) {
        this.apply(latest);
        this.failure = 'conflict';
        throw new Error('dashboard revision conflict');
      }
      const next = JSON.parse(JSON.stringify(latest)) as Record<string, Object>;
      if (patch.cards !== undefined) {
        next['cards'] = dashboardCards(patch.cards);
      }
      if (patch.hideIp !== undefined) {
        next['hideIp'] = patch.hideIp;
      }
      if (patch.services !== undefined) {
        if (!patch.services.some((slot: ServiceSlot): boolean => slot.visible)) {
          this.failure = 'lastService';
          this.draft = undefined;
          this.hasDraft = false;
          throw new Error('at least one service must remain enabled');
        }
        next['services'] = encodeServiceSlots(patch.services);
      }
      next['revision'] = expectedRevision + 1;
      this.apply(next);
      optimistic = true;
      await writeTextAsync(this.path, JSON.stringify(next));
      this.draft = undefined;
      this.hasDraft = false;
    } catch (e) {
      if (optimistic) {
        this.apply(previous);
      }
      if (this.failure === '') {
        this.failure = 'write';
      }
      throw e as Error;
    } finally {
      this.saving = false;
    }
  }

  async retryDraft(): Promise<void> {
    const draft = this.draft;
    if (draft !== undefined) {
      await this.commit(draft, this.revision);
    }
  }

  private decode(text: string): Record<string, Object> {
    const document = JSON.parse(text) as Record<string, Object>;
    if (document === null || Array.isArray(document) || document['version'] !== 1 ||
      !Number.isInteger(document['revision'] as number) || Number(document['revision']) < 1 ||
      !Array.isArray(document['cards']) || !Array.isArray(document['services']) ||
      typeof document['hideIp'] !== 'boolean') {
      throw new Error('invalid dashboard document');
    }
    const cards = document['cards'] as string[];
    if (!cards.every((id: string): boolean => typeof id === 'string')) {
      throw new Error('invalid dashboard cards');
    }
    decodeServiceSlots(document['services'] as Record<string, Object>[]);
    return document;
  }

  private apply(document: Record<string, Object>): void {
    this.document = document;
    this.revision = Number(document['revision']);
    this.cards = dashboardCards(document['cards'] as string[]);
    this.hideIp = document['hideIp'] as boolean;
    this.services = decodeServiceSlots(document['services'] as Record<string, Object>[]);
  }

  private migrate(legacy: Record<string, Object>, existing: boolean): Record<string, Object> {
    const rawLayout = legacy['serviceLayout'];
    let services: Record<string, Object>[] = [];
    if (rawLayout !== undefined) {
      if (typeof rawLayout !== 'string') {
        throw new Error('invalid legacy service layout');
      }
      const parsed = JSON.parse(rawLayout as string) as Record<string, Object>[];
      if (!Array.isArray(parsed)) {
        throw new Error('invalid legacy service layout');
      }
      services = parsed;
    }
    let cards = existing ? LEGACY_DASHBOARD_CARDS.slice() : DEFAULT_DASHBOARD_CARDS.slice();
    const rawCards = legacy['dashboardWidgets'];
    if (rawCards !== undefined) {
      const parsedCards = typeof rawCards === 'string' ? JSON.parse(rawCards as string) as string[] : rawCards as string[];
      if (!Array.isArray(parsedCards) || !parsedCards.every((id: string): boolean => typeof id === 'string')) {
        throw new Error('invalid legacy dashboard layout');
      }
      cards = dashboardCards(parsedCards);
    }
    const hideIp = legacy['hideIp'];
    return {
      'version': 1,
      'revision': 1,
      'cards': cards,
      'hideIp': typeof hideIp === 'boolean' ? hideIp as boolean : false,
      'services': encodeServiceSlots(decodeServiceSlots(services)),
      // 原偏好完整保留，后续改变显隐也不会覆盖旧扩展、未知 ID 和抽屉字段。
      'legacyPreferences': legacy
    };
  }
}

export const dashboardSettings: DashboardSettings = new DashboardSettings();

// 首页「服务状态」能检测的服务，以及用户对它们的排序和显隐。
// 品牌标志使用本地静态资源，保留各产品原始配色，来源见资源提交说明。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREF_LAYOUT = 'serviceLayout';
// 第一次使用时首页显示的服务。
const DEFAULT_VISIBLE: string[] = ['google', 'github', 'youtube', 'chatgpt'];

export enum ServiceCategory {
  Common,
  Ai,
  China
}

export interface ServiceInfo {
  id: string;
  name: ResourceStr;
  url: string; // HEAD 请求，收到任何 HTTP 响应都算可达
  icon: Resource;
  category: ServiceCategory;
}

export const SERVICE_CATALOG: ServiceInfo[] = [
  { id: 'google', name: 'Google', url: 'https://www.google.com/generate_204', icon: $r('app.media.svc_google'),
    category: ServiceCategory.Common },
  { id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/generate_204', icon: $r('app.media.svc_youtube'),
    category: ServiceCategory.Common },
  { id: 'github', name: 'GitHub', url: 'https://github.com/', icon: $r('app.media.svc_github'),
    category: ServiceCategory.Common },
  { id: 'telegram', name: 'Telegram', url: 'https://web.telegram.org/', icon: $r('app.media.svc_telegram'),
    category: ServiceCategory.Common },
  { id: 'x', name: 'X', url: 'https://x.com/', icon: $r('app.media.svc_x'),
    category: ServiceCategory.Common },
  { id: 'instagram', name: 'Instagram', url: 'https://www.instagram.com/', icon: $r('app.media.svc_instagram'),
    category: ServiceCategory.Common },
  { id: 'netflix', name: 'Netflix', url: 'https://www.netflix.com/', icon: $r('app.media.svc_netflix'),
    category: ServiceCategory.Common },
  { id: 'spotify', name: 'Spotify', url: 'https://open.spotify.com/', icon: $r('app.media.svc_spotify'),
    category: ServiceCategory.Common },
  { id: 'wikipedia', name: $r('app.string.svc_wikipedia'), url: 'https://www.wikipedia.org/',
    icon: $r('app.media.svc_wikipedia'), category: ServiceCategory.Common },
  { id: 'reddit', name: 'Reddit', url: 'https://www.reddit.com/', icon: $r('app.media.svc_reddit'),
    category: ServiceCategory.Common },
  { id: 'discord', name: 'Discord', url: 'https://discord.com/', icon: $r('app.media.svc_discord'),
    category: ServiceCategory.Common },
  { id: 'tiktok', name: 'TikTok', url: 'https://www.tiktok.com/', icon: $r('app.media.svc_tiktok'),
    category: ServiceCategory.Common },
  { id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/', icon: $r('app.media.svc_chatgpt'),
    category: ServiceCategory.Ai },
  { id: 'claude', name: 'Claude', url: 'https://claude.ai/', icon: $r('app.media.svc_claude'),
    category: ServiceCategory.Ai },
  { id: 'gemini', name: 'Gemini', url: 'https://gemini.google.com/', icon: $r('app.media.svc_gemini'),
    category: ServiceCategory.Ai },
  { id: 'perplexity', name: 'Perplexity', url: 'https://www.perplexity.ai/', icon: $r('app.media.svc_perplexity'),
    category: ServiceCategory.Ai },
  { id: 'deepseek', name: 'DeepSeek', url: 'https://chat.deepseek.com/', icon: $r('app.media.svc_deepseek'),
    category: ServiceCategory.Ai },
  { id: 'poe', name: 'Poe', url: 'https://poe.com/', icon: $r('app.media.svc_poe'),
    category: ServiceCategory.Ai },
  { id: 'huggingface', name: 'Hugging Face', url: 'https://huggingface.co/', icon: $r('app.media.svc_huggingface'),
    category: ServiceCategory.Ai },
  { id: 'bilibili', name: $r('app.string.svc_bilibili'), url: 'https://www.bilibili.com/',
    icon: $r('app.media.svc_bilibili'), category: ServiceCategory.China },
  { id: 'baidu', name: $r('app.string.svc_baidu'), url: 'https://www.baidu.com/', icon: $r('app.media.svc_baidu'),
    category: ServiceCategory.China },
  { id: 'netease', name: $r('app.string.svc_netease'), url: 'https://music.163.com/',
    icon: $r('app.media.svc_netease'), category: ServiceCategory.China }
];

export function serviceInfo(id: string): ServiceInfo | undefined {
  return SERVICE_CATALOG.find((s: ServiceInfo) => s.id === id);
}

/** 用户排好的一项：哪个服务、首页显不显示。 */
export interface ServiceSlot {
  id: string;
  visible: boolean;
}

function servicePriority(id: string): number {
  if (id === 'google') {
    return 0;
  }
  switch (serviceInfo(id)?.category) {
    case ServiceCategory.Ai:
      return 1;
    case ServiceCategory.China:
      return 3;
    default:
      return 2;
  }
}

/** Google 置顶、AI 集中在后；用户的同类排序和显隐保存在偏好里，新服务默认不显示。 */
@ObservedV2
export class ServiceLayout {
  @Trace slots: ServiceSlot[] = [];
  private prefs?: preferences.Preferences;

  load(context: common.UIAbilityContext): void {
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    let stored: ServiceSlot[] = [];
    try {
      stored = JSON.parse(this.prefs.getSync(PREF_LAYOUT, '[]') as string) as ServiceSlot[];
    } catch (e) {
      stored = [];
    }
    const known = stored.filter((s: ServiceSlot) => serviceInfo(s.id) !== undefined);
    const fresh = stored.length === 0;
    for (const info of SERVICE_CATALOG) {
      if (known.find((s: ServiceSlot) => s.id === info.id) === undefined) {
        known.push({ id: info.id, visible: fresh && DEFAULT_VISIBLE.includes(info.id) });
      }
    }
    if (fresh) {
      // 同类内默认显示的几项排在前面。
      known.sort((a: ServiceSlot, b: ServiceSlot) => Number(b.visible) - Number(a.visible));
    }
    this.slots = known.sort((a: ServiceSlot, b: ServiceSlot) => servicePriority(a.id) - servicePriority(b.id));
  }

  get visibleIds(): string[] {
    return this.slots.filter((s: ServiceSlot) => s.visible).map((s: ServiceSlot) => s.id);
  }

  move(from: number, to: number): void {
    const slots = [...this.slots];
    const moved = slots.splice(from, 1)[0];
    slots.splice(to, 0, moved);
    this.slots = slots.sort((a: ServiceSlot, b: ServiceSlot) => servicePriority(a.id) - servicePriority(b.id));
    this.save();
  }

  setVisible(id: string, visible: boolean): void {
    this.slots = this.slots.map((s: ServiceSlot): ServiceSlot => s.id === id ? { id: s.id, visible: visible } : s);
    this.save();
  }

  private save(): void {
    this.prefs?.putSync(PREF_LAYOUT, JSON.stringify(this.slots));
    this.prefs?.flush();
  }
}

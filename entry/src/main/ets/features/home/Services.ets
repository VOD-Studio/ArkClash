// 首页「服务状态」能检测的服务，以及用户对它们的排序和显隐。
// 图标来自 Simple Icons（CC0）；各品牌标志归其所有者，只用来标识服务。
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
  icon?: Resource; // 没有图标时用 short 做文字头像
  short: string;
  color: string; // 品牌色，#RRGGBB
  category: ServiceCategory;
}

export const SERVICE_CATALOG: ServiceInfo[] = [
  { id: 'google', name: 'Google', url: 'https://www.google.com/generate_204', icon: $r('app.media.svc_google'),
    short: 'G', color: '#4285F4', category: ServiceCategory.Common },
  { id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/generate_204', icon: $r('app.media.svc_youtube'),
    short: 'YT', color: '#FF0000', category: ServiceCategory.Common },
  { id: 'github', name: 'GitHub', url: 'https://github.com/', icon: $r('app.media.svc_github'),
    short: 'GH', color: '#181717', category: ServiceCategory.Common },
  { id: 'telegram', name: 'Telegram', url: 'https://web.telegram.org/', icon: $r('app.media.svc_telegram'),
    short: 'TG', color: '#26A5E4', category: ServiceCategory.Common },
  { id: 'x', name: 'X', url: 'https://x.com/', icon: $r('app.media.svc_x'),
    short: 'X', color: '#000000', category: ServiceCategory.Common },
  { id: 'instagram', name: 'Instagram', url: 'https://www.instagram.com/', icon: $r('app.media.svc_instagram'),
    short: 'IG', color: '#FF0069', category: ServiceCategory.Common },
  { id: 'netflix', name: 'Netflix', url: 'https://www.netflix.com/', icon: $r('app.media.svc_netflix'),
    short: 'N', color: '#E50914', category: ServiceCategory.Common },
  { id: 'spotify', name: 'Spotify', url: 'https://open.spotify.com/', icon: $r('app.media.svc_spotify'),
    short: 'S', color: '#1ED760', category: ServiceCategory.Common },
  { id: 'wikipedia', name: $r('app.string.svc_wikipedia'), url: 'https://www.wikipedia.org/',
    icon: $r('app.media.svc_wikipedia'), short: 'W', color: '#000000', category: ServiceCategory.Common },
  { id: 'reddit', name: 'Reddit', url: 'https://www.reddit.com/', icon: $r('app.media.svc_reddit'),
    short: 'R', color: '#FF4500', category: ServiceCategory.Common },
  { id: 'discord', name: 'Discord', url: 'https://discord.com/', icon: $r('app.media.svc_discord'),
    short: 'D', color: '#5865F2', category: ServiceCategory.Common },
  { id: 'tiktok', name: 'TikTok', url: 'https://www.tiktok.com/', icon: $r('app.media.svc_tiktok'),
    short: 'TT', color: '#000000', category: ServiceCategory.Common },
  { id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/', short: 'AI', color: '#10A37F',
    category: ServiceCategory.Ai },
  { id: 'claude', name: 'Claude', url: 'https://claude.ai/', icon: $r('app.media.svc_claude'),
    short: 'C', color: '#D97757', category: ServiceCategory.Ai },
  { id: 'gemini', name: 'Gemini', url: 'https://gemini.google.com/', icon: $r('app.media.svc_gemini'),
    short: 'Ge', color: '#8E75B2', category: ServiceCategory.Ai },
  { id: 'perplexity', name: 'Perplexity', url: 'https://www.perplexity.ai/', icon: $r('app.media.svc_perplexity'),
    short: 'P', color: '#1FB8CD', category: ServiceCategory.Ai },
  { id: 'deepseek', name: 'DeepSeek', url: 'https://chat.deepseek.com/', icon: $r('app.media.svc_deepseek'),
    short: 'DS', color: '#5786FE', category: ServiceCategory.Ai },
  { id: 'poe', name: 'Poe', url: 'https://poe.com/', icon: $r('app.media.svc_poe'),
    short: 'Po', color: '#5D5CDE', category: ServiceCategory.Ai },
  { id: 'huggingface', name: 'Hugging Face', url: 'https://huggingface.co/', icon: $r('app.media.svc_huggingface'),
    short: 'HF', color: '#FFD21E', category: ServiceCategory.Ai },
  { id: 'bilibili', name: $r('app.string.svc_bilibili'), url: 'https://www.bilibili.com/',
    icon: $r('app.media.svc_bilibili'), short: 'B', color: '#00A1D6', category: ServiceCategory.China },
  { id: 'baidu', name: $r('app.string.svc_baidu'), url: 'https://www.baidu.com/', icon: $r('app.media.svc_baidu'),
    short: 'Bd', color: '#2932E1', category: ServiceCategory.China },
  { id: 'netease', name: $r('app.string.svc_netease'), url: 'https://music.163.com/',
    icon: $r('app.media.svc_netease'), short: 'NE', color: '#D43C33', category: ServiceCategory.China }
];

export function serviceInfo(id: string): ServiceInfo | undefined {
  return SERVICE_CATALOG.find((s: ServiceInfo) => s.id === id);
}

/** 用户排好的一项：哪个服务、首页显不显示。 */
export interface ServiceSlot {
  id: string;
  visible: boolean;
}

/** 服务的排序和显隐，存在偏好里；目录里新加的服务排到最后，默认不显示。 */
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
      // 默认显示的几项排在最前面。
      known.sort((a: ServiceSlot, b: ServiceSlot) => Number(b.visible) - Number(a.visible));
    }
    this.slots = known;
  }

  get visibleIds(): string[] {
    return this.slots.filter((s: ServiceSlot) => s.visible).map((s: ServiceSlot) => s.id);
  }

  move(from: number, to: number): void {
    const slots = [...this.slots];
    const moved = slots.splice(from, 1)[0];
    slots.splice(to, 0, moved);
    this.slots = slots;
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

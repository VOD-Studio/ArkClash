export interface ServiceInfo {
  id: string;
  name: ResourceStr;
  url: string;
  icon: Resource;
}

export interface ServiceSlot {
  id: string;
  visible: boolean;
  legacy: boolean;
  raw: Record<string, Object>;
}

export const SERVICE_CATALOG: ServiceInfo[] = [
  { id: 'google', name: 'Google', url: 'https://www.google.com/generate_204', icon: $r('app.media.svc_google') },
  { id: 'github', name: 'GitHub', url: 'https://github.com/', icon: $r('app.media.svc_github') },
  { id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/generate_204', icon: $r('app.media.svc_youtube') },
  { id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/', icon: $r('app.media.svc_chatgpt') },
  { id: 'claude', name: 'Claude', url: 'https://claude.ai/', icon: $r('app.media.svc_claude') },
  { id: 'gemini', name: 'Gemini', url: 'https://gemini.google.com/', icon: $r('app.media.svc_gemini') },
  { id: 'netflix', name: 'Netflix', url: 'https://www.netflix.com/', icon: $r('app.media.svc_netflix') },
  { id: 'disney-plus', name: 'Disney+', url: 'https://www.disneyplus.com/', icon: $r('app.media.svc_disney') },
  { id: 'prime-video', name: 'Prime Video', url: 'https://www.primevideo.com/', icon: $r('app.media.svc_primevideo') },
  { id: 'spotify', name: 'Spotify', url: 'https://open.spotify.com/', icon: $r('app.media.svc_spotify') },
  { id: 'tiktok', name: 'TikTok', url: 'https://www.tiktok.com/', icon: $r('app.media.svc_tiktok') },
  { id: 'discord', name: 'Discord', url: 'https://discord.com/', icon: $r('app.media.svc_discord') },
  { id: 'bilibili', name: $r('app.string.svc_bilibili'), url: 'https://www.bilibili.com/',
    icon: $r('app.media.svc_bilibili') }
];

const LEGACY_SERVICES: ServiceInfo[] = [
  { id: 'telegram', name: 'Telegram', url: 'https://web.telegram.org/', icon: $r('app.media.svc_telegram') },
  { id: 'x', name: 'X', url: 'https://x.com/', icon: $r('app.media.svc_x') },
  { id: 'instagram', name: 'Instagram', url: 'https://www.instagram.com/', icon: $r('app.media.svc_instagram') },
  { id: 'wikipedia', name: $r('app.string.svc_wikipedia'), url: 'https://www.wikipedia.org/',
    icon: $r('app.media.svc_wikipedia') },
  { id: 'reddit', name: 'Reddit', url: 'https://www.reddit.com/', icon: $r('app.media.svc_reddit') },
  { id: 'perplexity', name: 'Perplexity', url: 'https://www.perplexity.ai/', icon: $r('app.media.svc_perplexity') },
  { id: 'deepseek', name: 'DeepSeek', url: 'https://chat.deepseek.com/', icon: $r('app.media.svc_deepseek') },
  { id: 'poe', name: 'Poe', url: 'https://poe.com/', icon: $r('app.media.svc_poe') },
  { id: 'huggingface', name: 'Hugging Face', url: 'https://huggingface.co/', icon: $r('app.media.svc_huggingface') },
  { id: 'baidu', name: $r('app.string.svc_baidu'), url: 'https://www.baidu.com/', icon: $r('app.media.svc_baidu') },
  { id: 'netease', name: $r('app.string.svc_netease'), url: 'https://music.163.com/', icon: $r('app.media.svc_netease') }
];

export function serviceInfo(id: string): ServiceInfo | undefined {
  return SERVICE_CATALOG.find((info: ServiceInfo): boolean => info.id === id) ??
    LEGACY_SERVICES.find((info: ServiceInfo): boolean => info.id === id);
}

export function decodeServiceSlots(stored: Record<string, Object>[]): ServiceSlot[] {
  const slots: ServiceSlot[] = [];
  const seen: Set<string> = new Set<string>();
  for (const record of stored) {
    const id = record['id'] as string;
    if (typeof id !== 'string' || id === '' || seen.has(id)) {
      continue;
    }
    const visible = record['visible'];
    if (visible !== undefined && typeof visible !== 'boolean') {
      throw new Error('invalid service visibility');
    }
    seen.add(id);
    slots.push({
      id: id,
      visible: visible === undefined ? true : visible as boolean,
      legacy: !SERVICE_CATALOG.some((info: ServiceInfo): boolean => info.id === id),
      raw: record
    });
  }
  for (const info of SERVICE_CATALOG) {
    if (!seen.has(info.id)) {
      slots.push({ id: info.id, visible: true, legacy: false, raw: { 'id': info.id, 'visible': true } });
    }
  }
  return slots;
}

export function encodeServiceSlots(slots: ServiceSlot[]): Record<string, Object>[] {
  return slots.map((slot: ServiceSlot): Record<string, Object> => {
    const record = JSON.parse(JSON.stringify(slot.raw)) as Record<string, Object>;
    record['id'] = slot.id;
    record['visible'] = slot.visible;
    return record;
  });
}

import { url } from '@kit.ArkTS';

export interface IconSetImage {
  name: string;
  url: string;
}

export interface ImportedIconSet {
  name: string;
  icons: IconSetImage[];
}

export interface ProfileIconSet {
  id: string;
  name: string;
  url: string;
  updatedAt: number;
  icons: IconSetImage[];
}

export interface IconSetSnapshot {
  revision: string;
  sets: ProfileIconSet[];
}

export interface IconSetDownloadCommand {
  expectedRevision: string;
  revision: string;
  id: string;
  name: string;
  url: string;
}

export const ICON_SET_MANIFEST_LIMIT = 4 * 1024 * 1024;
const ICON_SET_MAX_IMAGES = 12000;
const ICON_DATA_LIMIT = 256 * 1024;

export function validIconSetUrl(source: string): boolean {
  if (typeof source !== 'string' || source.length > 2048 || /[\s\\]/.test(source)) { return false; }
  try {
    const parsed = new url.URL(source);
    return (parsed.protocol === 'https:' || parsed.protocol === 'http:') && parsed.hostname !== '' &&
      parsed.username === '' && parsed.password === '';
  } catch (_error) { return false; }
}

export function validGroupIconSource(source: string): boolean {
  return validIconSetUrl(source) || (typeof source === 'string' && source.length <= ICON_DATA_LIMIT &&
    /^data:image\/(?:png|jpeg|bmp|webp);base64,[a-z0-9+/]+={0,2}$/i.test(source));
}

export function iconSetLoopback(source: string): boolean {
  const host = new url.URL(source).hostname;
  return host === 'localhost' || host === '[::1]' || /^127(?:\.\d{1,3}){3}$/.test(host);
}

export function iconFileName(source: string): string {
  const path = new url.URL(source).pathname;
  const name = path.split('/').pop() ?? '';
  try { return decodeURIComponent(name); } catch (_error) { return name; }
}

export function iconSetLabel(name: string): string {
  return name.replace(/\.[^./]+$/, '').replace(/_/g, ' ').trim();
}

export function parseIconSetManifest(text: string): ImportedIconSet {
  const manifest = JSON.parse(text.replace(/^\ufeff/, '')) as ImportedIconSet;
  if (manifest === null || !Array.isArray(manifest.icons) || manifest.icons.length > ICON_SET_MAX_IMAGES) {
    throw new Error('icon_set_invalid');
  }
  const seen = new Set<string>();
  const images: IconSetImage[] = [];
  for (const raw of manifest.icons) {
    if (raw === null || !validIconSetUrl(raw.url) || seen.has(raw.url)) { continue; }
    seen.add(raw.url);
    const name = typeof raw.name === 'string' ? raw.name.trim() : '';
    const fallback = name === '' ? iconFileName(raw.url) : '';
    images.push({ name: (name || fallback).slice(0, 160), url: raw.url });
  }
  if (images.length === 0) { throw new Error('icon_set_invalid'); }
  return { name: typeof manifest.name === 'string' ? manifest.name.trim().slice(0, 80) : '', icons: images };
}

export function checkIconSetSnapshot(snapshot: IconSetSnapshot): IconSetSnapshot {
  if (snapshot === null || typeof snapshot.revision !== 'string' || snapshot.revision === '' ||
    snapshot.revision.length > 80 || !Array.isArray(snapshot.sets)) {
    throw new Error('icon_set_invalid');
  }
  const ids = new Set<string>();
  const urls = new Set<string>();
  for (const item of snapshot.sets) {
    if (item === null || typeof item.id !== 'string' || item.id === '' || ids.has(item.id) ||
      typeof item.name !== 'string' || item.name.trim() === '' || item.name.length > 80 ||
      typeof item.url !== 'string' || (item.url !== '' && (!validIconSetUrl(item.url) || urls.has(item.url))) ||
      !Number.isFinite(item.updatedAt) || !Array.isArray(item.icons) || item.icons.length === 0 ||
      item.icons.length > ICON_SET_MAX_IMAGES ||
      item.icons.some((icon: IconSetImage): boolean => icon === null || typeof icon.name !== 'string' ||
        !validIconSetUrl(icon.url))) {
      throw new Error('icon_set_invalid');
    }
    ids.add(item.id);
    if (item.url !== '') { urls.add(item.url); }
  }
  return snapshot;
}

export function makeIconSet(id: string, label: string, source: string, fallback: string,
  manifest: ImportedIconSet): ProfileIconSet {
  return { id: id, url: source, name: (label.trim() || manifest.name || iconSetLabel(fallback) || 'Icons').slice(0, 80),
    updatedAt: Date.now(), icons: manifest.icons };
}

interface RankedIconSetImage {
  icon: IconSetImage;
  score: number;
  nameLength: number;
}

export function rankIconSetImages(icons: IconSetImage[], group: string): IconSetImage[] {
  const target = group.toLowerCase().replace(/[^a-z0-9]/g, '');
  if (target === '') { return []; }
  const ranked: RankedIconSetImage[] = [];
  const seen = new Set<string>();
  for (const icon of icons) {
    const name = iconSetLabel(icon.name).toLowerCase().replace(/[^a-z0-9]/g, '');
    let score = 0;
    if (name === target) { score = 3; }
    else if (name.length >= 3 && target.includes(name)) { score = 2; }
    else if (target.length >= 3 && name.includes(target)) { score = 1; }
    if (score > 0 && !seen.has(icon.url)) {
      seen.add(icon.url);
      ranked.push({ icon: icon, score: score, nameLength: name.length });
    }
  }
  ranked.sort((a: RankedIconSetImage, b: RankedIconSetImage): number => b.score - a.score || a.nameLength - b.nameLength);
  return ranked.slice(0, 24).map((entry: RankedIconSetImage): IconSetImage => entry.icon);
}

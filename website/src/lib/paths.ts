/** 拼接 Astro `base` 前缀，确保在 GitHub Pages 子路径和自定义根域名下链接均有效。 */
export function withBase(path: string): string {
  if (/^(https?:|mailto:|#)/.test(path)) return path;
  const base = import.meta.env.BASE_URL.replace(/\/+$/, '');
  const clean = path.startsWith('/') ? path : `/${path}`;
  return `${base}${clean}`;
}

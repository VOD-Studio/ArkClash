import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import tailwindcss from '@tailwindcss/vite';

// 默认指向 GitHub Pages 子路径；CI 中由 configure-pages 注入真实 origin/base_path（支持自定义域名）。
const hasPagesEnv = Boolean(process.env.PAGES_ORIGIN);
const site = process.env.SITE_URL || process.env.PAGES_ORIGIN || 'https://vod-studio.github.io';
const base =
  process.env.SITE_BASE !== undefined
    ? process.env.SITE_BASE
    : hasPagesEnv
      ? (process.env.PAGES_BASE_PATH ?? '')
      : '/ArkClash';

export default defineConfig({
  site,
  base,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'ArkClash',
      description: '基于 mihomo 的原生 HarmonyOS NEXT 代理客户端，双进程隔离、轻量省电、支持热切换与进阶覆写。',
      defaultLocale: 'root',
      locales: {
        root: {
          label: '简体中文',
          lang: 'zh-CN',
        },
      },
      logo: {
        src: './src/assets/icon.png',
        alt: 'ArkClash 图标',
      },
      favicon: '/favicon.png',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/VOD-Studio/ArkClash',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/VOD-Studio/ArkClash/edit/main/website/',
      },
      lastUpdated: false,
      customCss: ['./src/styles/starlight.css'],
      components: {
        Footer: './src/components/DocsFooter.astro',
      },
      head: [
        {
          tag: 'meta',
          attrs: {
            name: 'theme-color',
            content: '#007AFF',
          },
        },
      ],
      sidebar: [
        {
          label: '快速开始',
          items: [
            { slug: 'getting-started/introduction' },
            { slug: 'getting-started/installation' },
            { slug: 'getting-started/first-connection' },
          ],
        },
        {
          label: '使用指南',
          items: [
            { slug: 'guide/profiles' },
            { slug: 'guide/proxies' },
            { slug: 'guide/diagnostics-and-geo' },
            { slug: 'guide/theme-and-backup' },
          ],
        },
        {
          label: '进阶配置',
          items: [
            { slug: 'advanced/overrides' },
            { slug: 'advanced/scripts' },
            { slug: 'advanced/rules-and-resources' },
            { slug: 'advanced/network-and-dns' },
          ],
        },
        {
          label: '开发与架构',
          collapsed: true,
          items: [
            { slug: 'developer/build-from-source' },
            { slug: 'developer/architecture' },
            { slug: 'developer/platform-pitfalls' },
            { slug: 'developer/ci-and-release' },
            { slug: 'developer/fork-setup' },
            { slug: 'developer/contributing' },
            { slug: 'developer/security' },
            { slug: 'developer/glossary' },
            { slug: 'developer/changelog' },
            {
              label: '架构决策记录（ADR）',
              collapsed: true,
              items: [{ autogenerate: { directory: 'developer/adr' } }],
            },
          ],
        },
      ],
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});

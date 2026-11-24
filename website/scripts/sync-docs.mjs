#!/usr/bin/env bun
/**
 * 同步仓库根目录与 docs/ 下的真实文档、ADR、元数据与视觉资源到 website/。
 * 保持单一真相源，避免仓库文档与网站文档漂移。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE_DIR = path.resolve(__dirname, '..');
const REPO_DIR = path.resolve(SITE_DIR, '..');
const GITHUB_BLOB = 'https://github.com/VOD-Studio/ArkClash/blob/main';

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function readUtf8(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function writeIfChanged(filePath, content) {
  ensureDir(path.dirname(filePath));
  if (fs.existsSync(filePath) && fs.readFileSync(filePath, 'utf8') === content) {
    return;
  }
  fs.writeFileSync(filePath, content, 'utf8');
}

function copyIfExists(src, dest) {
  if (!fs.existsSync(src)) return;
  ensureDir(path.dirname(dest));
  fs.copyFileSync(src, dest);
}

/** 剥离首行 H1 标题，由 Starlight frontmatter title 渲染，避免页面出现重复大标题。 */
function stripLeadingH1(markdown) {
  const match = markdown.match(/^\uFEFF?#\s+(.+)\r?\n+/);
  if (!match) return { h1: '', body: markdown };
  return {
    h1: match[1].trim(),
    body: markdown.slice(match[0].length),
  };
}

function escapeYaml(str) {
  return JSON.stringify(str);
}

function buildFrontmatter({ title, description, sidebarOrder, sidebarLabel, badge, editPath }) {
  const lines = ['---'];
  lines.push(`title: ${escapeYaml(title)}`);
  if (description) lines.push(`description: ${escapeYaml(description)}`);
  if (editPath) lines.push(`editUrl: ${escapeYaml(`${GITHUB_BLOB}/${editPath}`)}`);
  if (sidebarOrder !== undefined || sidebarLabel || badge) {
    lines.push('sidebar:');
    if (sidebarLabel) lines.push(`  label: ${escapeYaml(sidebarLabel)}`);
    if (sidebarOrder !== undefined) lines.push(`  order: ${sidebarOrder}`);
    if (badge) {
      lines.push('  badge:');
      lines.push(`    text: ${escapeYaml(badge.text)}`);
      if (badge.variant) lines.push(`    variant: ${escapeYaml(badge.variant)}`);
    }
  }
  lines.push('---', '');
  return lines.join('\n');
}

/**
 * 改写仓库相对 Markdown 链接为站点路径或 GitHub 原文链接。
 * 忽略围栏代码块内的内容，避免误改示例命令。
 */
function rewriteLinks(markdown, rewriter) {
  const lines = markdown.split('\n');
  let inFence = false;
  const out = lines.map((line) => {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      return line;
    }
    if (inFence) return line;
    return line.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (full, text, target) => {
      if (
        target.startsWith('http://') ||
        target.startsWith('https://') ||
        target.startsWith('mailto:') ||
        target.startsWith('#')
      ) {
        return full;
      }
      const [rawPath, hash = ''] = target.split('#');
      const next = rewriter(rawPath);
      if (!next) return full;
      return `[${text}](${hash ? `${next}#${hash}` : next})`;
    });
  });
  return out.join('\n');
}

function syncAssets() {
  const docsAssets = path.join(REPO_DIR, 'docs/assets');
  copyIfExists(
    path.join(docsAssets, 'icon.png'),
    path.join(SITE_DIR, 'public/favicon.png'),
  );
  copyIfExists(
    path.join(docsAssets, 'icon.png'),
    path.join(SITE_DIR, 'public/assets/icon.png'),
  );
  copyIfExists(
    path.join(docsAssets, 'icon.png'),
    path.join(SITE_DIR, 'src/assets/icon.png'),
  );
  copyIfExists(
    path.join(docsAssets, 'screenshot-dashboard.webp'),
    path.join(SITE_DIR, 'public/assets/screenshot-dashboard.webp'),
  );
  for (const file of fs.readdirSync(docsAssets)) {
    if (file.startsWith('screenshot-') && file.endsWith('.webp')) {
      copyIfExists(path.join(docsAssets, file), path.join(SITE_DIR, 'src/assets', file));
    }
  }

  // 同步仓库内置的服务品牌 SVG，供官网「13 项主流服务协议探测」展示使用
  const mediaDir = path.join(REPO_DIR, 'entry/src/main/resources/base/media');
  const servicesOut = path.join(SITE_DIR, 'public/assets/services');
  ensureDir(servicesOut);
  if (fs.existsSync(mediaDir)) {
    for (const file of fs.readdirSync(mediaDir)) {
      if (file.startsWith('svc_') && file.endsWith('.svg')) {
        fs.copyFileSync(path.join(mediaDir, file), path.join(servicesOut, file));
      }
    }
  }
}

function syncDocs() {
  const devDir = path.join(SITE_DIR, 'src/content/docs/developer');
  const adrOutDir = path.join(devDir, 'adr');
  ensureDir(devDir);
  ensureDir(adrOutDir);

  const singleDocs = [
    {
      src: 'docs/architecture.md',
      dest: path.join(devDir, 'architecture.md'),
      title: '系统架构',
      description: 'ArkClash 双进程结构、连接时序、状态归属、ArkTS 分层与 Go 内核模块总览。',
      sidebarOrder: 2,
      rewriter: (p) => {
        const m = p.match(/^adr\/([0-9]{4}-[^/]+)\.md$/);
        if (m) return `../adr/${m[1]}/`;
        return null;
      },
    },
    {
      src: 'docs/agents/platform-pitfalls.md',
      dest: path.join(devDir, 'platform-pitfalls.md'),
      title: '鸿蒙平台陷阱与补丁',
      description: 'musl TLSDESC 冲突、Go 出站物理网络绑定、SELinux TUN fstat 拒绝与 netlink 禁用等底层实践记录。',
      sidebarOrder: 3,
      rewriter: (p) => {
        const m = p.match(/^\.\.\/adr\/([0-9]{4}-[^/]+)\.md$/);
        if (m) return `../adr/${m[1]}/`;
        return null;
      },
    },
    {
      src: 'docs/ci.md',
      dest: path.join(devDir, 'ci-and-release.md'),
      title: 'CI/CD 与发版流程',
      description: '分层流水线、Geo 数据镜像、体积预算、密钥配置与 release-please 自动发版说明。',
      sidebarOrder: 4,
      rewriter: (p) => {
        const m = p.match(/^adr\/([0-9]{4}-[^/]+)\.md$/);
        if (m) return `../adr/${m[1]}/`;
        return null;
      },
    },
    {
      src: 'docs/agents/fork-setup.md',
      dest: path.join(devDir, 'fork-setup.md'),
      title: 'Fork 环境准备',
      description: '接手新 Fork 或在新机器首次搭建 HarmonyOS NEXT 构建、签名与 CI 环境的完整步骤。',
      sidebarOrder: 5,
      rewriter: () => null,
    },
    {
      src: 'CONTRIBUTING.md',
      dest: path.join(devDir, 'contributing.md'),
      title: '参与贡献与性能基准',
      description: '提交 issue、提 PR 规范、宿主回归测试与真机冷启动 / 连接延迟基准测试方法。',
      sidebarOrder: 6,
      rewriter: (p) => {
        if (p === 'SECURITY.md') return '../security/';
        if (p === 'docs/agents/fork-setup.md') return '../fork-setup/';
        if (p === 'AGENTS.md') return `${GITHUB_BLOB}/AGENTS.md`;
        if (p === 'CODE_OF_CONDUCT.md') return `${GITHUB_BLOB}/CODE_OF_CONDUCT.md`;
        if (p === 'docs/agents/git.md') return `${GITHUB_BLOB}/docs/agents/git.md`;
        return null;
      },
    },
    {
      src: 'SECURITY.md',
      dest: path.join(devDir, 'security.md'),
      title: '安全策略',
      description: '支持的安全更新版本、私密漏洞报告渠道与安全边界说明。',
      sidebarOrder: 7,
      rewriter: () => null,
    },
    {
      src: 'GLOSSARY.md',
      dest: path.join(devDir, 'glossary.md'),
      title: '领域术语表',
      description: 'ArkClash 界面、文档、issue 与架构决策中统一使用的领域词汇定义。',
      sidebarOrder: 8,
      rewriter: () => null,
    },
    {
      src: 'CHANGELOG.md',
      dest: path.join(devDir, 'changelog.md'),
      title: '更新日志',
      description: 'ArkClash 各版本的新增功能、架构演进与修复记录。',
      sidebarOrder: 9,
      rewriter: () => null,
    },
  ];

  for (const item of singleDocs) {
    const raw = readUtf8(path.join(REPO_DIR, item.src));
    const { body } = stripLeadingH1(raw);
    const transformed = rewriteLinks(body, item.rewriter);
    const fm = buildFrontmatter({
      title: item.title,
      description: item.description,
      sidebarOrder: item.sidebarOrder,
      editPath: item.src,
    });
    writeIfChanged(item.dest, `${fm}${transformed.trimStart()}`);
  }

  // 同步全部 ADR 文档（docs/adr/0001-*.md ..）
  const adrSrcDir = path.join(REPO_DIR, 'docs/adr');
  const adrFiles = fs
    .readdirSync(adrSrcDir)
    .filter((f) => /^[0-9]{4}-.*\.md$/.test(f))
    .sort();

  // 清理旧的生成文件，避免仓库删除 ADR 后残留死页
  for (const existing of fs.readdirSync(adrOutDir)) {
    if (existing !== 'index.md' && !adrFiles.includes(existing)) {
      fs.rmSync(path.join(adrOutDir, existing), { force: true });
    }
  }

  const adrList = [];
  for (const file of adrFiles) {
    const raw = readUtf8(path.join(adrSrcDir, file));
    const { h1, body } = stripLeadingH1(raw);
    const slug = file.replace(/\.md$/, '');
    const numMatch = slug.match(/^(\d{4})/);
    const num = numMatch ? Number.parseInt(numMatch[1], 10) : 9999;
    const title = h1 || slug;

    const statusMatch =
      body.match(/-\s*状态[：:]\s*(.+)/) || body.match(/##\s*状态\r?\n+\s*(.+)/);
    const status = statusMatch ? statusMatch[1].trim().replace(/。$/, '') : '';
    const isSuperseded = status.includes('已被');

    adrList.push({
      id: numMatch ? numMatch[1] : slug,
      slug,
      title,
      status,
    });

    const transformed = rewriteLinks(body, (p) => {
      const m = p.match(/^([0-9]{4}-[^/]+)\.md$/);
      if (m) return `../${m[1]}/`;
      return null;
    });

    const fm = buildFrontmatter({
      title,
      description: status ? `架构决策记录 ${title}（${status}）` : `架构决策记录 ${title}`,
      sidebarOrder: num,
      badge: isSuperseded ? { text: '已取代', variant: 'caution' } : undefined,
      editPath: `docs/adr/${file}`,
    });
    writeIfChanged(path.join(adrOutDir, file), `${fm}${transformed.trimStart()}`);
  }

  // 同步 ADR 索引页
  const adrReadmeRaw = readUtf8(path.join(adrSrcDir, 'README.md'));
  const { body: adrReadmeBody } = stripLeadingH1(adrReadmeRaw);
  const adrIndexTransformed = rewriteLinks(adrReadmeBody, (p) => {
    const m = p.match(/^([0-9]{4}-[^/]+)\.md$/);
    if (m) return `./${m[1]}/`;
    return null;
  });
  const adrIndexFm = buildFrontmatter({
    title: '架构决策记录（ADR）',
    description: `ArkClash 关键技术取舍与设计理由的完整记录，共收录 ${adrFiles.length} 篇决策文档。`,
    sidebarLabel: '索引总览',
    sidebarOrder: 0,
    editPath: 'docs/adr/README.md',
  });
  writeIfChanged(path.join(adrOutDir, 'index.md'), `${adrIndexFm}${adrIndexTransformed.trimStart()}`);

  return adrList;
}

function writeMetadata(adrList) {
  const manifest = JSON.parse(readUtf8(path.join(REPO_DIR, '.release-please-manifest.json')));
  const goVersion = readUtf8(path.join(REPO_DIR, '.go-version')).trim();
  const meta = {
    version: manifest['.'] || '0.6.0',
    goVersion,
    adrCount: adrList.length,
    repoUrl: 'https://github.com/VOD-Studio/ArkClash',
    releasesUrl: 'https://github.com/VOD-Studio/ArkClash/releases/latest',
    issuesUrl: 'https://github.com/VOD-Studio/ArkClash/issues',
  };
  writeIfChanged(
    path.join(SITE_DIR, 'src/generated/meta.json'),
    `${JSON.stringify(meta, null, 2)}\n`,
  );
}

syncAssets();
const adrList = syncDocs();
writeMetadata(adrList);
console.log(`[sync-docs] 同步完成：已生成开发文档与 ${adrList.length} 篇 ADR。`);

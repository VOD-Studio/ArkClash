// 把打包在 rawfile/geo 里的 Geo 数据复制到内核的 homeDir。
// 有了这些文件，内核启动时不用再去 GitHub 现场下载。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// 文件名要和 mihomo 查找的一致（constant/path.go，不区分大小写）。
const GEO_FILES: string[] = ['geoip.metadb', 'geosite.dat'];
// scripts/fetch-geodata.sh 生成，内容是上面各文件的 SHA-256。
const BUNDLED_VERSION = 'geo/VERSION';
// 复制完成后在 homeDir 留一份，下次启动和安装包里的比对。
const INSTALLED_VERSION = 'geo.version';

/**
 * 安装包里的 Geo 数据版本和已安装的不同、或文件缺失时才复制。返回复制了几个文件。
 * 全程异步：首次复制要写十几 MB，不能卡住 VPN 进程的主线程。
 */
export async function installGeoData(context: common.Context, homeDir: string): Promise<number> {
  const resources = context.resourceManager;
  let bundled: string;
  try {
    bundled = util.TextDecoder.create('utf-8').decodeToString(await resources.getRawFileContent(BUNDLED_VERSION));
  } catch (e) {
    // 没跑 scripts/fetch-geodata.sh 的开发构建里没有这些文件，交给内核自己下载。
    return 0;
  }

  const stampPath = `${homeDir}/${INSTALLED_VERSION}`;
  if (await isInstalled(homeDir, stampPath, bundled)) {
    return 0;
  }
  for (const name of GEO_FILES) {
    const data = await resources.getRawFileContent(`geo/${name}`);
    await writeFile(`${homeDir}/${name}`, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
  }
  // 版本最后写：中途失败的话，下次启动版本对不上，会重新复制。
  await writeFile(stampPath, bundled);
  return GEO_FILES.length;
}

async function isInstalled(homeDir: string, stampPath: string, bundled: string): Promise<boolean> {
  try {
    if ((await fs.readText(stampPath)) !== bundled) {
      return false;
    }
    for (const name of GEO_FILES) {
      if (!(await fs.access(`${homeDir}/${name}`))) {
        return false;
      }
    }
    return true;
  } catch (e) {
    // 首次启动还没有版本文件。
    return false;
  }
}

async function writeFile(path: string, content: ArrayBuffer | string): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, content);
  } finally {
    await fs.close(file);
  }
}

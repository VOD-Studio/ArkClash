// 把打包在 rawfile/geo 里的 Geo 数据复制到内核的 homeDir。
// 有了这些文件，内核启动时不用再去 GitHub 现场下载。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  GeoResourceId, GeoResourceStatus, geoMissingFile, readGeoFileInfos, readGeoMetadata, readGeoOptionalText
} from '../shared/GeoResources';

// 安装包只携带这两份数据，另外两项由用户在线获取。
const GEO_FILES: string[] = ['geoip.metadb', 'geosite.dat'];
const GEO_IDS: GeoResourceId[] = ['mmdb', 'geosite'];
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
  const installed = await readGeoOptionalText(stampPath);
  const infos = await readGeoFileInfos(homeDir);
  let copied = 0;
  for (let index = 0; index < GEO_IDS.length; index++) {
    const id = GEO_IDS[index];
    const info = infos.find((item: GeoResourceStatus): boolean => item.id === id);
    if (info === undefined || info.error === 'geo_io') { throw new Error('geo_io'); }
    if (info.exists) {
      // 损坏的元数据不能证明尚未接管，保守保护已有数据库。
      if (info.error === 'geo_metadata_invalid') { continue; }
      const metadata = await readGeoMetadata(homeDir, id);
      if (metadata?.managed === true || installed === bundled) { continue; }
    }
    const data = await resources.getRawFileContent(`geo/${GEO_FILES[index]}`);
    await writeFile(`${homeDir}/${info.fileName}`,
      data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    copied++;
  }
  // 所有复制成功后才更新版本；中断时不留下半份活动文件或成功标记。
  if (installed !== bundled) {
    const stamp = new util.TextEncoder().encodeInto(bundled);
    await writeFile(stampPath, stamp.buffer.slice(stamp.byteOffset, stamp.byteOffset + stamp.byteLength));
  }
  return copied;
}

async function writeFile(path: string, content: ArrayBuffer): Promise<void> {
  const temporary = `${path}.${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}.tmp`;
  let committed = false;
  try {
    const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      if (await fs.write(file.fd, content) !== content.byteLength) { throw new Error('geo_io'); }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
    await fs.rename(temporary, path);
    committed = true;
  } finally {
    if (!committed) {
      try { await fs.unlink(temporary); }
      catch (error) { if (!geoMissingFile(error as Object)) { throw new Error('geo_io'); } }
    }
  }
}

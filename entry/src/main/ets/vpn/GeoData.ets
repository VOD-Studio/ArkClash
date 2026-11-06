// 把打包在 rawfile/geo 里的 Geo 数据复制到内核的 homeDir。
// 有了这些文件，内核启动时不用再去 GitHub 现场下载。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hasFile } from '../shared/Runtime';

// 文件名要和 mihomo 查找的一致（constant/path.go，不区分大小写）。
const GEO_FILES: string[] = ['geoip.metadb', 'geosite.dat'];

/** 目标文件不存在、或大小和安装包里的不同（应用更新过）时才复制。返回复制了几个文件。 */
export function installGeoData(context: common.Context, homeDir: string): number {
  let copied = 0;
  for (const name of GEO_FILES) {
    const rawPath = `geo/${name}`;
    let length = 0;
    try {
      length = context.resourceManager.getRawFdSync(rawPath).length;
      context.resourceManager.closeRawFdSync(rawPath);
    } catch (e) {
      // 没跑 scripts/fetch-geodata.sh 的开发构建里没有这些文件，交给内核自己下载。
      continue;
    }

    const target = `${homeDir}/${name}`;
    if (hasFile(target) && fs.statSync(target).size === length) {
      continue;
    }
    const data = context.resourceManager.getRawFileContentSync(rawPath);
    const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    } finally {
      fs.closeSync(file);
    }
    copied++;
  }
  return copied;
}

// 把打包在 rawfile/geo 里的 Geo 数据复制到内核的 homeDir。
// 有了这些文件，内核启动时不用再去 GitHub 现场下载。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

// 文件名要和 mihomo 查找的一致（constant/path.go，不区分大小写）。
const GEO_FILES: string[] = ['geoip.metadb', 'geosite.dat'];

/**
 * 目标文件不存在、或大小和安装包里的不同（应用更新过）时才复制。返回复制了几个文件。
 * 全程异步：首次复制要写十几 MB，不能卡住 VPN 进程的主线程。
 */
export async function installGeoData(context: common.Context, homeDir: string): Promise<number> {
  const resources = context.resourceManager;
  let copied = 0;
  for (const name of GEO_FILES) {
    const rawPath = `geo/${name}`;
    let length = 0;
    try {
      length = (await resources.getRawFd(rawPath)).length;
      await resources.closeRawFd(rawPath);
    } catch (e) {
      // 没跑 scripts/fetch-geodata.sh 的开发构建里没有这些文件，交给内核自己下载。
      continue;
    }

    const target = `${homeDir}/${name}`;
    if ((await fs.access(target)) && (await fs.stat(target)).size === length) {
      continue;
    }
    const data = await resources.getRawFileContent(rawPath);
    await writeFile(target, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    copied++;
  }
  return copied;
}

async function writeFile(path: string, content: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, content);
  } finally {
    await fs.close(file);
  }
}

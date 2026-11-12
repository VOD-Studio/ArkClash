// 阶段 0 真机实验用的日志，只存在于实验分支。格式和 core/exp.go 的 expLog 一致。
import { hidebug, hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';

const DOMAIN = 0x0A11;
const TAG = 'ArkClashExp';

/** side 是 'ui' 或 'vpn'；message 用 key=value 形式，方便脚本解析。 */
export function expLog(side: string, message: string): void {
  hilog.info(DOMAIN, TAG, 'EXP t=%{public}d side=%{public}s pid=%{public}d %{public}s', Date.now(), side,
    process.pid, message);
}

/** 本进程的内存占用，单位 KB。 */
export function memoryText(): string {
  return `pss_kb=${Number(hidebug.getPss())} private_dirty_kb=${Number(hidebug.getPrivateDirty())} ` +
    `shared_dirty_kb=${Number(hidebug.getSharedDirty())} native_heap_kb=${Number(hidebug.getNativeHeapSize()) / 1024}`;
}

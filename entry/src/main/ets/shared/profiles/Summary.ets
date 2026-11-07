import { taskpool } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { readText, writeTextAsync } from '../Files';
import { analyzeText, AnalyzeResult, ProfileSummary } from './Analyze';
import { summaryPath } from './Store';

export { ProfileSummary, SummaryGroup } from './Analyze';

// 配置可能有几 MB，读文件和解析都放在 TaskPool 里，主线程只拿结果。
@Concurrent
function analyzeFile(path: string): AnalyzeResult {
  let text: string;
  try {
    text = fs.readTextSync(path);
  } catch (e) {
    return { error: `io:${(e as Error).message}`, summary: '' };
  }
  return analyzeText(text);
}

/** 检查 path 的内容；不通过时 error 非空，通过时 summary 是摘要的 JSON。 */
export async function analyze(path: string): Promise<AnalyzeResult> {
  return await taskpool.execute(analyzeFile, path) as AnalyzeResult;
}

export async function writeSummary(filesDir: string, profile: string, summaryJson: string): Promise<void> {
  await writeTextAsync(summaryPath(filesDir, profile), summaryJson);
}

export async function readSummary(filesDir: string, profile: string): Promise<ProfileSummary | undefined> {
  const text = await readText(summaryPath(filesDir, profile));
  if (text === undefined) {
    return undefined;
  }
  try {
    return JSON.parse(text) as ProfileSummary;
  } catch (e) {
    return undefined;
  }
}

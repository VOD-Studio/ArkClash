import { taskpool } from '@kit.ArkTS';
import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { readOptionalText, summaryPath, writeProfileText } from './Store';
import { analyzeText, AnalyzeResult, ProfileSummary } from './Analyze';

export { ProfileSummary, SummaryGroup, SummaryProxy } from './Analyze';

// 配置可能有几 MB，读文件和解析都放在 TaskPool 里，主线程只拿结果。
@Concurrent
function analyzeFile(path: string): AnalyzeResult {
  let text: string;
  try {
    text = fs.readTextSync(path);
  } catch (e) {
    return { error: 'io', summary: '' };
  }
  return analyzeText(text);
}

/** 检查 path 的内容；不通过时 error 非空，通过时 summary 是摘要的 JSON。 */
export async function analyze(path: string): Promise<AnalyzeResult> {
  const result = await taskpool.execute(analyzeFile, path) as AnalyzeResult;
  if (result.error !== '') { return result; }
  try {
    const summary = JSON.parse(result.summary) as ProfileSummary;
    summary.revision = await hash.hash(path, 'sha256');
    return { error: '', summary: JSON.stringify(summary) };
  } catch (e) { return { error: 'io', summary: '' }; }
}

export async function writeSummary(filesDir: string, profile: string, summaryJson: string): Promise<void> {
  await writeProfileText(summaryPath(filesDir, profile), summaryJson);
}

export async function readSummary(filesDir: string, profile: string): Promise<ProfileSummary | undefined> {
  const text = await readOptionalText(summaryPath(filesDir, profile));
  if (text === undefined) {
    return undefined;
  }
  try {
    const summary = JSON.parse(text) as ProfileSummary;
    if (summary === null || !Array.isArray(summary.groups) || !Number.isFinite(summary.proxies) || summary.proxies < 0) {
      throw new Error('corrupt');
    }
    return summary;
  } catch (e) {
    throw new Error('corrupt');
  }
}

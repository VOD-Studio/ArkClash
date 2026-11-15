import { errorString } from '../../shared/profiles/Errors';
import { ProfileBatchFailure, ProfileBatchResult } from './ProfileModels';

export interface ProfileBatchJob {
  id: string;
  name: string;
  line?: number;
  run: () => Promise<string | undefined>;
}

export async function runProfileBatch(jobs: ProfileBatchJob[], skipped: number,
  onProgress?: (done: number, total: number) => void): Promise<ProfileBatchResult> {
  const result: ProfileBatchResult = { total: jobs.length, succeeded: 0, skipped: skipped, failures: [] };
  let cursor = 0;
  let completed = 0;
  const report = (done: number, total: number): void => {
    if (onProgress !== undefined) { onProgress(done, total); }
  };
  report(0, jobs.length);
  const worker = async (): Promise<void> => {
    while (cursor < jobs.length) {
      const job = jobs[cursor++];
      let failure: string | undefined;
      try { failure = await job.run(); } catch (e) { failure = errorString(e as Object); }
      if (failure === undefined) { result.succeeded++; }
      else {
        const detail: ProfileBatchFailure = { id: job.id, name: job.name, line: job.line, error: failure };
        result.failures.push(detail);
      }
      report(++completed, jobs.length);
    }
  };
  const workers: Promise<void>[] = [];
  for (let index = 0; index < Math.min(4, jobs.length); index++) { workers.push(worker()); }
  await Promise.all<void>(workers);
  return result;
}

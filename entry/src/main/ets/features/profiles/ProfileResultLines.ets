import { ProfileBatchFailure } from './ProfileModels';

export interface ProfileResultLine {
  key: string;
  description: boolean;
  error: string;
  name: string;
  line?: number;
  first: boolean;
  last: boolean;
}

export function profileResultLines(failures: ProfileBatchFailure[]): ProfileResultLine[] {
  const groups: Map<string, ProfileBatchFailure[]> = new Map<string, ProfileBatchFailure[]>();
  for (const failure of failures) {
    let group: ProfileBatchFailure[] | undefined = groups.get(failure.error);
    if (group === undefined) { group = []; groups.set(failure.error, group); }
    group.push(failure);
  }
  const rows: ProfileResultLine[] = [];
  groups.forEach((group: ProfileBatchFailure[], error: string): void => {
    const occurrences: Map<string, number> = new Map<string, number>();
    group.forEach((failure: ProfileBatchFailure, index: number): void => {
      const identity: string = JSON.stringify([error, failure.id,
        failure.line === undefined ? '' : failure.line.toString(), failure.name]);
      const occurrence: number = occurrences.get(identity) ?? 0;
      occurrences.set(identity, occurrence + 1);
      const row: ProfileResultLine = {
        key: `failure:${identity}:${occurrence}`, description: false, error: error,
        name: failure.name, line: failure.line, first: index === 0, last: index === group.length - 1
      };
      rows.push(row);
    });
    const description: ProfileResultLine = {
      key: `error:${JSON.stringify(error)}`, description: true, error: error,
      name: '', first: false, last: false
    };
    rows.push(description);
  });
  return rows;
}

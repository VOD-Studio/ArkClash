import { readFileSync, writeFileSync, unlinkSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const fixtures = readFileSync(new URL('../core/internal/testdata/contracts.json', import.meta.url), 'utf8');
const generated = new URL('../entry/src/test/ContractFixtures.ets', import.meta.url);
const log = new URL('../entry/.test/default/intermediates/test/coverage_data/coverage.log', import.meta.url);
const hvigor = process.env.HVIGORW;
const args = ['test', '-p', 'module=entry', '-p', 'coverage=false', '--no-daemon'];
const options = { stdio: 'inherit', timeout: 120000 };
writeFileSync(generated, `export const contractFixtures: string = ${JSON.stringify(fixtures)};\n`, { flag: 'wx' });
try {
  const started = Date.now();
  const result = process.platform === 'win32' && hvigor.endsWith('.bat') ?
    spawnSync(`"${hvigor}" ${args.join(' ')}`, { ...options, shell: true }) : spawnSync(hvigor, args, options);
  if (result.error) { throw result.error; }
  if (result.status !== 0) {
    process.exitCode = result.status ?? 1;
  } else {
    const summary = statSync(log).mtimeMs >= started && readFileSync(log, 'utf8').match(
      /OHOS_REPORT_RESULT: stream=Tests run: (\d+), Failure: 0, Error: 0, Pass: \1, Ignore: 0/
    );
    if (!summary || Number(summary[1]) === 0) {
      throw new Error('Local Test 没有生成全部通过的用例报告');
    }
    console.log(`ArkTS Local Test 通过：${summary[1]} 项`);
  }
} finally {
  unlinkSync(generated);
}

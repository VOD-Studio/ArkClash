import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const entry = new URL('../../entry/', import.meta.url);
const fixtures = readFileSync(new URL('../../core/internal/testdata/contracts.json', import.meta.url), 'utf8');

function load(source, resolve) {
  const loaded = { exports: {} };
  const input = readFileSync(new URL(source, entry), 'utf8');
  const compiled = ts.transpileModule(input, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
  });
  new Function('exports', 'require', compiled.outputText)(loaded.exports, resolve);
  return loaded.exports;
}

const { verifySettingsContract, verifyConfigInputContract } = load('src/test/ContractCases.ets', (name) => {
  switch (name) {
    case '../main/ets/client/ProfileSettingsProtocol':
      return load('src/main/ets/client/ProfileSettingsProtocol.ets', require);
    case '../main/ets/shared/GeneralSettingsModel':
      return load('src/main/ets/shared/GeneralSettingsModel.ets', require);
    case '../main/ets/shared/profiles/Analyze':
      return load('src/main/ets/shared/profiles/Analyze.ets', (dependency) => {
        if (dependency !== 'yaml') { throw new Error(`未知依赖 ${dependency}`); }
        return require(fileURLToPath(new URL('oh_modules/yaml/dist/index.js', entry)));
      });
    default:
      throw new Error(`未知依赖 ${name}`);
  }
});

test('常规设置默认值、跨语言 JSON 和错误字段', () => verifySettingsContract(fixtures));
test('配置摘要保留共享 YAML 数据的名称和组内顺序', () => verifyConfigInputContract(fixtures));

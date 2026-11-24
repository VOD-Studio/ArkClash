import { checkedGeneralSettings, defaultGeneralSettings, GeneralSettings } from '../main/ets/shared/GeneralSettingsModel';
import { analyzeText, ProfileSummary } from '../main/ets/shared/profiles/Analyze';
import { ProfileSettingsRequest, profileSettingsRequestJson } from '../main/ets/client/ProfileSettingsProtocol';

interface ContractConfigurationFixture {
  yaml: string;
  baseGroup: string;
}

interface ContractTestFixtures {
  defaultSettings: GeneralSettings;
  settingsRequest: ProfileSettingsRequest<GeneralSettings>;
  invalidSettingsRequest: ProfileSettingsRequest<GeneralSettings>;
  settingsError: Record<string, string>;
  configuration: ContractConfigurationFixture;
}

export function verifySettingsContract(text: string): void {
  const fixture = JSON.parse(text) as ContractTestFixtures;
  const defaults = defaultGeneralSettings();
  const fields = Object.keys(fixture.defaultSettings).sort();
  if (Object.keys(defaults).sort().join(',') !== fields.join(',') ||
    JSON.stringify(defaults, fields) !== JSON.stringify(fixture.defaultSettings, fields)) {
    throw new Error('常规设置默认值与契约不一致');
  }
  const request = fixture.settingsRequest;
  const settings = checkedGeneralSettings(request.settings);
  if (request.bootId !== 'fixture-boot' || request.expectedRevision !== defaults.revision ||
    settings.revision !== '9007199254740993' || settings.userAgent !== '契约测试 🧪' ||
    settings.closeConnections !== false || settings.captureLogs !== false ||
    settings.coreOverrides?.testUrl !== 'https://cp.cloudflare.com/generate_204' ||
    settings.coreOverrides?.unifiedDelay !== true || settings.coreOverrides?.tcpConcurrent !== false ||
    settings.coreOverrides?.ipv6 !== false || settings.coreOverrides?.geodataLoader !== 'memconservative') {
    throw new Error('请求字段应保留原始文本、修订、内核覆写和显式 false');
  }
  if (profileSettingsRequestJson<GeneralSettings>(request.bootId, request.expectedRevision, settings) !==
    JSON.stringify(request)) {
    throw new Error('ArkTS 请求序列化与共享契约不一致');
  }
  try {
    checkedGeneralSettings(fixture.invalidSettingsRequest.settings);
  } catch (error) {
    if ((error as Error).message === fixture.settingsError['message']) {
      return;
    }
    throw new Error((error as Error).message);
  }
  throw new Error('应拒绝以字符串表示的超时字段');
}

export function verifyConfigInputContract(text: string): void {
  const fixture = (JSON.parse(text) as ContractTestFixtures).configuration;
  const result = analyzeText(fixture.yaml);
  if (result.error !== '') {
    throw new Error(result.error);
  }
  const summary = JSON.parse(result.summary) as ProfileSummary;
  if (summary.groups.length !== 1 || summary.groups[0].name !== fixture.baseGroup ||
    summary.groups[0].members.join(',') !== 'DIRECT,REJECT') {
    throw new Error('配置摘要未按原文保留代理组名称与成员顺序');
  }
}

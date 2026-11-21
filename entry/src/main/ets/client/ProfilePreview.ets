import { http } from '@kit.NetworkKit';
import { call } from '../shared/ControllerRequest';

const PREVIEW_TIMEOUT_MS = 20000;
const PREVIEW_MAX_BYTES = 32 * 1024 * 1024;

export interface RuntimeProfilePreview {
  profile: string;
  bootId: string;
  configRevision: number;
  contentRevision: string;
  contentHash: string;
  applied: boolean;
  runningProfile: string;
  customRules: boolean;
  scriptIdentity?: string;
  yaml: string;
}

export function isPreviewHostUnavailable(error: Object): boolean {
  const message = (error as Error).message ?? '';
  const code = message.split(':')[0];
  if (code === 'preview_core_unavailable' || message === 'core is not running') {
    return true;
  }
  const lower = message.toLowerCase();
  return lower.includes('couldn\'t connect') || lower.includes('connection refused') ||
    lower.includes('failed to connect');
}

/** 追踪运行时预览请求代次与目标配置，防止切换配置后旧响应覆盖新页面。 */
export class ProfilePreviewGuard {
  private generation: number = 0;
  private activeProfile: string = '';

  begin(profile: string): number {
    this.activeProfile = profile;
    return ++this.generation;
  }

  cancel(): void {
    ++this.generation;
  }

  accepts(token: number, profile: string): boolean {
    return token === this.generation && profile !== '' && profile === this.activeProfile;
  }
}

export async function fetchProfilePreview(filesDir: string, profileId: string): Promise<RuntimeProfilePreview> {
  const encoded = encodeURIComponent(profileId);
  const text = await call(filesDir, http.RequestMethod.GET, `/arkclash/profiles/preview?profile=${encoded}`,
    undefined, PREVIEW_TIMEOUT_MS, PREVIEW_MAX_BYTES);
  let parsed: RuntimeProfilePreview;
  try {
    parsed = JSON.parse(text) as RuntimeProfilePreview;
  } catch (_error) {
    throw new Error('preview_build_failed');
  }
  if (typeof parsed.profile !== 'string' || typeof parsed.yaml !== 'string' ||
    typeof parsed.applied !== 'boolean' || !Number.isInteger(parsed.configRevision)) {
    throw new Error('preview_build_failed');
  }
  return parsed;
}

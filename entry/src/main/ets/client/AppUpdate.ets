import { bundleManager, common } from '@kit.AbilityKit';
import { updateManager } from '@kit.AppGalleryKit';
import { request as transfer } from '@kit.BasicServicesKit';
import { fileIo as fs, hash, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { removeFile } from '../shared/Files';

const RELEASES = 'https://github.com/VOD-Studio/ArkClash/releases';
const LATEST_RELEASE = 'https://api.github.com/repos/VOD-Studio/ArkClash/releases/latest';
const VERSION = /^v?(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})$/;
const SHA256 = /^sha256:[a-f0-9]{64}$/;
const MAX_PACKAGE_BYTES = 256 * 1024 * 1024;
const AUTO_CHECK_DELAY_MS = 1500;
const DOWNLOAD_TIMEOUT_MS = 5 * 60 * 1000;
const AUTO_CHECK = 'autoCheck';
const UPDATE_CACHE = 'arkclash-update.hap';

interface AppReleaseResponse {
  tag_name: string;
  assets: AppReleaseResponseAsset[];
}

interface AppReleaseResponseAsset {
  name: string;
  size: number;
  digest?: string;
}

export interface AppReleaseAsset {
  name: string;
  size: number;
  digest: string;
  url: string;
}

export interface AppReleaseStatus {
  installed: string;
  available: string;
  galleryUpdate: boolean;
  assets: AppReleaseAsset[];
}

type AppUpdatePhase = 'idle' | 'downloading' | 'verifying' | 'ready' | 'saving' | 'installing';

export function appReleaseUrl(tag: string): string {
  return `${RELEASES}/tag/${encodeURIComponent(tag)}`;
}

export function isNewerRelease(installed: string, release: string): boolean {
  const before = VERSION.exec(installed);
  const after = VERSION.exec(release);
  if (before === null || after === null) { throw new Error('app_update_version'); }
  for (let index = 1; index <= 3; index++) {
    const delta = Number(after[index]) - Number(before[index]);
    if (delta !== 0) { return delta > 0; }
  }
  return false;
}

function releaseAssets(release: AppReleaseResponse): AppReleaseAsset[] {
  const version = release.tag_name.replace(/^v/, '');
  const assets: AppReleaseAsset[] = [];
  for (const variant of ['unsigned', 'debug-signed']) {
    const name = `ArkClash-${version}-${variant}.hap`;
    const entry = release.assets.find((item: AppReleaseResponseAsset): boolean => item?.name === name);
    if (entry === undefined || typeof entry.digest !== 'string' || !SHA256.test(entry.digest) ||
      !Number.isSafeInteger(entry.size) || entry.size <= 0 || entry.size > MAX_PACKAGE_BYTES) { continue; }
    assets.push({ name: name, size: entry.size, digest: entry.digest.slice(7),
      url: `${RELEASES}/download/${encodeURIComponent(release.tag_name)}/${name}` });
  }
  return assets;
}

async function checkAppRelease(context: common.UIAbilityContext): Promise<AppReleaseStatus> {
  const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
  const installed = bundle.versionName;
  if (bundle.appInfo.appDistributionType === 'app_gallery') {
    const result = await updateManager.checkAppUpdate(context);
    return { installed: installed, available: '', assets: [],
      galleryUpdate: result.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST };
  }
  const request = http.createHttp();
  try {
    const response = await request.request(LATEST_RELEASE, {
      method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, maxLimit: 512 * 1024,
      connectTimeout: 5000, readTimeout: 10000, usingCache: false,
      header: { 'Accept': 'application/vnd.github+json', 'User-Agent': 'ArkClash' }
    });
    if (response.responseCode !== 200 || typeof response.result !== 'string') { throw new Error('app_update_request'); }
    const release = JSON.parse(response.result) as AppReleaseResponse;
    if (typeof release?.tag_name !== 'string' || !Array.isArray(release.assets)) {
      throw new Error('app_update_version');
    }
    const available = isNewerRelease(installed, release.tag_name) ? release.tag_name : '';
    return { installed: installed, available: available, galleryUpdate: false,
      assets: available === '' ? [] : releaseAssets(release) };
  } finally {
    request.destroy();
  }
}

@ObservedV2
export class AppUpdateState {
  @Trace release?: AppReleaseStatus;
  @Trace checking: boolean = false;
  @Trace checkFailed: boolean = false;
  @Trace automatic: boolean = true;
  @Trace preferenceReady: boolean = false;
  @Trace preferenceSaving: boolean = false;
  @Trace phase: AppUpdatePhase = 'idle';
  @Trace asset?: AppReleaseAsset;
  @Trace received: number = 0;

  private prefs?: preferences.Preferences;
  private preferenceLoad?: Promise<void>;
  private foreground: boolean = false;
  private autoChecked: boolean = false;
  private autoTimer: number = -1;
  private canceled: boolean = false;
  private cancelTransfer?: () => void;
  private cachePath: string = '';

  private loadPreference(context: common.UIAbilityContext): Promise<void> {
    if (this.preferenceLoad === undefined) {
      this.preferenceLoad = this.readPreference(context);
    }
    return this.preferenceLoad;
  }

  private async readPreference(context: common.UIAbilityContext): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, { name: 'app-update' });
      this.automatic = await this.prefs.get(AUTO_CHECK, true) !== false;
      this.preferenceReady = true;
    } catch (_error) {
      this.preferenceLoad = undefined;
    }
  }

  async setForeground(context: common.UIAbilityContext, foreground: boolean): Promise<void> {
    this.foreground = foreground;
    if (!foreground) {
      this.clearAutoTimer();
      return;
    }
    await this.loadPreference(context);
    this.scheduleAutoCheck(context);
  }

  async setAutomatic(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    await this.loadPreference(context);
    const prefs = this.prefs;
    if (prefs === undefined || !this.preferenceReady) { throw new Error('app_update_preference'); }
    if (this.preferenceSaving || this.automatic === enabled) { return; }
    this.preferenceSaving = true;
    this.clearAutoTimer();
    try {
      await prefs.put(AUTO_CHECK, enabled);
      await prefs.flush();
      this.automatic = enabled;
    } catch (_error) {
      await prefs.put(AUTO_CHECK, this.automatic).catch((): void => {});
      throw new Error('app_update_preference');
    } finally {
      this.preferenceSaving = false;
      this.scheduleAutoCheck(context);
    }
  }

  private clearAutoTimer(): void {
    if (this.autoTimer === -1) { return; }
    clearTimeout(this.autoTimer);
    this.autoTimer = -1;
  }

  private scheduleAutoCheck(context: common.UIAbilityContext): void {
    if (!this.foreground || !this.preferenceReady || !this.automatic || this.preferenceSaving ||
      this.autoChecked || this.autoTimer !== -1) { return; }
    this.autoTimer = setTimeout((): void => {
      this.autoTimer = -1;
      this.check(context, true);
    }, AUTO_CHECK_DELAY_MS);
  }

  async check(context: common.UIAbilityContext, automatic: boolean = false): Promise<void> {
    if (this.checking || this.phase !== 'idle') { return; }
    this.autoChecked = true;
    this.clearAutoTimer();
    this.checking = true;
    this.checkFailed = false;
    try {
      this.release = await checkAppRelease(context);
    } catch (_error) {
      this.checkFailed = !automatic;
    } finally {
      this.checking = false;
    }
  }

  async install(context: common.UIAbilityContext): Promise<void> {
    if (!this.release?.galleryUpdate || this.phase !== 'idle' || this.checking) { return; }
    this.phase = 'installing';
    try {
      const result = await updateManager.showUpdateDialog(context);
      if (result !== updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS) { throw new Error('app_update_install'); }
    } finally {
      this.phase = 'idle';
    }
  }

  async download(context: common.UIAbilityContext, name: string): Promise<void> {
    if (this.phase !== 'idle' || this.checking) { return; }
    const asset = this.release?.assets.find((item: AppReleaseAsset): boolean => item.name === name);
    if (asset === undefined) { return; }
    this.phase = 'downloading';
    this.asset = asset;
    this.received = 0;
    this.canceled = false;
    this.cachePath = `${context.cacheDir}/${UPDATE_CACHE}`;
    try {
      await removeFile(this.cachePath);
      if (this.canceled) { return; }
      const task = await transfer.agent.create(context, {
        action: transfer.agent.Action.DOWNLOAD, mode: transfer.agent.Mode.FOREGROUND,
        url: asset.url, saveas: this.cachePath, title: asset.name, metered: true, retry: false
      });
      try {
        if (this.canceled || !(await this.waitForDownload(task, asset.size))) { return; }
      } finally {
        await transfer.agent.remove(task.tid).catch((): void => {});
      }
      if (this.canceled) { return; }
      this.phase = 'verifying';
      if ((await fs.stat(this.cachePath)).size !== asset.size ||
        (await hash.hash(this.cachePath, 'sha256')).toLowerCase() !== asset.digest) {
        throw new Error('app_update_checksum');
      }
      if (!this.canceled) { this.phase = 'ready'; }
    } catch (error) {
      if (!this.canceled) {
        throw new Error((error as Error).message === 'app_update_checksum' ? 'app_update_checksum' : 'app_update_download');
      }
    } finally {
      if (this.phase !== 'ready') { await this.clearPackage(); }
    }
  }

  private async waitForDownload(task: transfer.agent.Task, size: number): Promise<boolean> {
    let timer = -1;
    let lastProgress = 0;
    try {
      return await new Promise<boolean>((resolve, reject) => {
        this.cancelTransfer = (): void => resolve(false);
        timer = setTimeout((): void => reject(new Error('app_update_download')), DOWNLOAD_TIMEOUT_MS);
        task.on('failed', (): void => reject(new Error('app_update_download')));
        task.on('remove', (): void => reject(new Error('app_update_download')));
        task.on('completed', (): void => resolve(true));
        task.on('progress', (progress: transfer.agent.Progress): void => {
          if (progress.processed > size) {
            reject(new Error('app_update_checksum'));
          } else if (Date.now() - lastProgress >= 250) {
            lastProgress = Date.now();
            this.received = progress.processed;
          }
        });
        task.start().catch((): void => reject(new Error('app_update_download')));
      });
    } finally {
      clearTimeout(timer);
      this.cancelTransfer = undefined;
    }
  }

  async cancel(): Promise<void> {
    if (this.phase === 'ready') {
      this.phase = 'saving';
      await this.clearPackage();
    } else if (this.phase === 'downloading' || this.phase === 'verifying') {
      this.canceled = true;
      this.cancelTransfer?.();
    }
  }

  async save(context: common.UIAbilityContext): Promise<boolean> {
    const asset = this.asset;
    if (this.phase !== 'ready' || asset === undefined) { return false; }
    this.phase = 'saving';
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [asset.name];
      options.fileSuffixChoices = ['HAP|.hap'];
      const targets = await new picker.DocumentViewPicker(context).save(options);
      if (targets.length === 0) { return false; }
      const source = await fs.open(this.cachePath, fs.OpenMode.READ_ONLY);
      try {
        const target = await fs.open(targets[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { await fs.copyFile(source.fd, target.fd); }
        finally { await fs.close(target); }
      } finally {
        await fs.close(source);
      }
      await this.clearPackage();
      return true;
    } finally {
      if (this.phase === 'saving') { this.phase = 'ready'; }
    }
  }

  private async clearPackage(): Promise<void> {
    await removeFile(this.cachePath);
    this.asset = undefined;
    this.received = 0;
    this.phase = 'idle';
  }
}

export const appUpdateState: AppUpdateState = new AppUpdateState();

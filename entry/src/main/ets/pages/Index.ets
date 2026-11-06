// Milestone 1 page: just enough UI to prove the core works on a device.
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { probeCore, startCore, stopCore } from '../common/CoreClient';
import { downloadProfile, hasProfile } from '../common/Profiles';

const PREF_URL = 'subscriptionUrl';

@Entry
@Component
struct Index {
  @State subscriptionUrl: string = '';
  @State profileReady: boolean = false;
  @State connected: boolean = false;
  @State busy: boolean = false;
  @State coreVersion: string = '';
  @State message: string = '';
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private prefs?: preferences.Preferences;

  aboutToAppear(): void {
    this.prefs = preferences.getPreferencesSync(this.context, { name: 'settings' });
    this.subscriptionUrl = this.prefs.getSync(PREF_URL, '') as string;
    this.profileReady = hasProfile(this.context.filesDir);
    // Render first; the core state arrives in the background.
    probeCore(this.context).then((version: string | undefined) => {
      if (version !== undefined) {
        this.connected = true;
        this.coreVersion = version;
      }
    });
  }

  async download(): Promise<void> {
    this.busy = true;
    this.message = '';
    try {
      const size = await downloadProfile(this.context.filesDir, this.subscriptionUrl.trim());
      this.prefs?.putSync(PREF_URL, this.subscriptionUrl.trim());
      this.prefs?.flush();
      this.profileReady = true;
      this.message = `订阅已更新（${(size / 1024).toFixed(1)} KB）`;
    } catch (e) {
      this.message = `下载失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  async toggle(): Promise<void> {
    this.busy = true;
    this.message = '';
    try {
      if (this.connected) {
        await stopCore(this.context);
        this.connected = false;
      } else {
        this.coreVersion = await startCore(this.context);
        this.connected = true;
      }
    } catch (e) {
      this.message = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 16 }) {
      Text('ArkClash')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)

      TextInput({ placeholder: '订阅链接', text: this.subscriptionUrl })
        .onChange((value: string) => {
          this.subscriptionUrl = value;
        })

      Button(this.profileReady ? '更新订阅' : '下载订阅')
        .width('100%')
        .enabled(!this.busy && this.subscriptionUrl.trim().length > 0)
        .onClick(() => {
          this.download();
        })

      Button(this.connected ? '断开' : '连接')
        .width('100%')
        .height(56)
        .enabled(!this.busy && (this.connected || this.profileReady))
        .backgroundColor(this.connected ? '#E5484D' : '#0A59F7')
        .onClick(() => {
          this.toggle();
        })

      if (this.connected) {
        Text(`已连接 · mihomo ${this.coreVersion}`)
          .fontColor('#30A46C')
      }

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(14)
          .fontColor('#8B8D98')
      }
    }
    .padding(24)
    .width('100%')
    .height('100%')
  }
}

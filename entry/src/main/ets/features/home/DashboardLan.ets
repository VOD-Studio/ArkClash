import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { getAllowLan, getProxyPort } from '../../client/Controller';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { lanAddress } from './LanAddress';

@ComponentV2
export struct DashboardLan {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param routeRevision: string = '';
  @Local conn: Connection = connection;
  @Local address: string = '';
  @Local port: number = 0;
  @Local effectiveAllow: boolean = false;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  @Local changing: boolean = false;
  private generation: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.generation++;
  }

  @Monitor('visible', 'routeRevision', 'conn.routeRevision', 'conn.state')
  sync(): void {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    const generation = ++this.generation;
    if (!this.visible) {
      return;
    }
    this.loading = true;
    this.failed = false;
    this.effectiveAllow = false;
    this.port = 0;
    try {
      const address = await lanAddress();
      if (generation !== this.generation) {
        return;
      }
      this.address = address;
      if (this.conn.connected) {
        const port = await getProxyPort(this.context.filesDir);
        const allow = await getAllowLan(this.context.filesDir);
        if (generation === this.generation) {
          this.port = port;
          this.effectiveAllow = allow;
        }
      }
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      if (generation === this.generation) {
        this.loading = false;
      }
    }
  }

  private async changeAllow(allow: boolean): Promise<void> {
    if (!this.interactive || this.changing || allow === this.desired()) {
      return;
    }
    this.changing = true;
    try {
      await this.conn.changeAllowLan(allow);
      await this.refresh();
      if (this.conn.connected && this.effectiveAllow !== allow) {
        throw new Error('allow-lan not applied');
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_lan_failed') });
    } finally {
      this.changing = false;
    }
  }

  private desired(): boolean {
    return this.conn.allowLan ?? this.effectiveAllow;
  }

  private proxyReady(): boolean {
    return this.conn.connected && this.effectiveAllow && this.port > 0 && !this.failed && !this.loading;
  }

  private async copy(): Promise<void> {
    if (!this.interactive || this.address === '' || this.loading || this.failed) {
      return;
    }
    const text = this.proxyReady() ? `${this.address}:${this.port}` : this.address;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copied') });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_copy_failed') });
    }
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_lan_ip'), symbol: $r('sys.symbol.wifi') })
      Text(this.loading ? $r('app.string.dash_groups_loading') : this.failed ? $r('app.string.dash_lan_failed') :
        this.address || $r('app.string.no_network'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .maxLines(2)
      Row() {
        Text($r('app.string.lan_proxy'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.desired() })
          .enabled(this.interactive && !this.changing && !this.loading)
          .onChange((allow: boolean): void => { this.changeAllow(allow); })
      }
      .width('100%')
      Text(this.proxyReady() ? `${this.address}:${this.port}` : this.desired() ?
        $r('app.string.lan_proxy_pending') : $r('app.string.lan_proxy_off'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
      Row({ space: 8 }) {
        Button($r('app.string.dash_copy_address'))
          .enabled(this.interactive && this.address !== '' && !this.loading && !this.failed)
          .onClick((): void => { this.copy(); })
        Button($r('app.string.dash_retry'))
          .enabled(this.interactive && !this.loading)
          .onClick((): void => { this.refresh(); })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}

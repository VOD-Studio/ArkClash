import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { getAllowLan, getProxyPort } from '../../client/Controller';
import { DASHBOARD_CARD } from '../../components/Theme';
import { lanAddress } from './LanAddress';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardHeaderAction } from './DashboardHeaderAction';
import { DASHBOARD_COOKIE6 } from './DashboardShapePaths';

@ComponentV2
export struct DashboardLan {
  @Local private appStyle: AppearanceState = appAppearance;
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
    Column() {
      Row({ space: 8 }) {
        AppGlyph({ name: 'devices', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
        Text($r('app.string.card_lan_ip'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .lineHeight(20)
          .fontWeight(600)
          .layoutWeight(1)
        DashboardHeaderAction({ glyph: 'copy', actionLabel: $r('app.string.dash_copy_address'), xShift: 8,
          active: this.interactive && this.address !== '' && !this.loading && !this.failed,
          onPress: (): void => { this.copy(); } })
      }
      .width('100%')
      .constraintSize({ minHeight: 26 })
      Text(this.loading ? $r('app.string.dash_groups_loading') : this.failed ? $r('app.string.dash_lan_failed') :
        this.address || $r('app.string.no_network'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(28)
        .minFontSize(21)
        .maxFontSize(28)
        .lineHeight(34)
        .fontWeight(FontWeight.Bold)
        .fontFeature('"tnum" on')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 12 })
      Row({ space: 12 }) {
        Stack() {
          if (this.desired()) {
            Shape() {
              Path().commands(DASHBOARD_COOKIE6).fill(this.appStyle.palette.brand).strokeWidth(0)
            }
            .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
            .width(38)
            .height(38)
          } else {
            Circle({ width: 38, height: 38 }).fill(this.appStyle.palette.cardBackground).strokeWidth(0)
          }
          AppGlyph({ name: 'wifi', iconSize: 19,
            iconColor: this.desired() ? Color.White : $r('sys.color.font_secondary') })
        }
        .width(38)
        .height(38)
        Column() {
          Text($r('app.string.lan_proxy'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
          Text(this.proxyReady() ? `${this.address}:${this.port}` : this.desired() ?
            $r('app.string.lan_proxy_pending') : $r('app.string.lan_proxy_off'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.desired() })
          .enabled(this.interactive && !this.changing && !this.loading)
          .onChange((allow: boolean): void => { this.changeAllow(allow); })
      }
      .width('100%')
      .padding({ left: 10, right: 12, top: 10, bottom: 10 })
      .borderRadius(20)
      .backgroundColor(this.appStyle.palette.tileBackground)
      .margin({ top: 14 })
      if (this.failed) {
        Button($r('app.string.dash_retry'))
          .fontFamily(this.appStyle.fontFamily)
          .enabled(this.interactive && !this.loading)
          .onClick((): void => { this.refresh(); })
          .margin({ top: 8 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }
}

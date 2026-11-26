import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { uiResourceText } from '../../components/ResourceText';

const BUTTON_STAGE_SIZE = 84;
const BUTTON_HALO_SIZE = 82;
const BUTTON_BODY_SIZE = 68;
const BUTTON_CIRCLE_RADIUS = 34;
const BUTTON_SQUIRCLE_RADIUS = 22;
const BUTTON_HALO_CIRCLE_RADIUS = 41;
const BUTTON_HALO_SQUIRCLE_RADIUS = 29;
const MORPH_SPRING = curves.springMotion(0.36, 0.74);
const HALO_SPRING = curves.springMotion(0.38, 0.76);

function shadowHex(argb: number): string {
  return `#${(argb >>> 0).toString(16).padStart(8, '0')}`;
}

@ComponentV2
struct RunButtonFace {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param running: boolean = false;
  @Param busy: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param visible: boolean = false;

  @Local private loadingShown: boolean = false;
  @Local private busyPulsing: boolean = false;
  @Local private ripplePhase: number = 0;
  private appeared: boolean = false;
  private wasSettledRunning: boolean = false;
  private loadingGeneration: number = 0;
  private rippleGeneration: number = 0;
  private rippleExpandTimer: number = -1;
  private rippleResetTimer: number = -1;

  aboutToAppear(): void {
    this.syncLoading();
  }

  aboutToDisappear(): void {
    this.appeared = false;
    this.loadingGeneration++;
    this.loadingShown = false;
    this.busyPulsing = false;
    this.clearRipple();
  }

  @Monitor('busy', 'visible', 'motionEnabled')
  syncLoading(): void {
    this.loadingGeneration++;
    if (this.busy || !this.visible || !this.motionEnabled) {
      this.loadingShown = this.visible && this.busy;
    }
    this.busyPulsing = this.appeared && this.busy && this.visible && this.motionEnabled;
  }

  @Monitor('running', 'busy', 'visible', 'motionEnabled')
  syncRipple(): void {
    const settledRunning = this.running && !this.busy;
    if (settledRunning && !this.wasSettledRunning && this.appeared && this.visible && this.motionEnabled) {
      this.triggerRipple();
    } else if (!settledRunning || !this.visible || !this.motionEnabled) {
      this.clearRipple();
    }
    this.wasSettledRunning = settledRunning;
  }

  private clearRipple(): void {
    this.rippleGeneration++;
    if (this.rippleExpandTimer !== -1) {
      clearTimeout(this.rippleExpandTimer);
      this.rippleExpandTimer = -1;
    }
    if (this.rippleResetTimer !== -1) {
      clearTimeout(this.rippleResetTimer);
      this.rippleResetTimer = -1;
    }
    this.ripplePhase = 0;
  }

  // 连接落定后播一次向外消散的同心圆角波纹，结束后完全静止不占电量。
  private triggerRipple(): void {
    this.clearRipple();
    const generation = this.rippleGeneration;
    this.ripplePhase = 1;
    this.rippleExpandTimer = setTimeout((): void => {
      this.rippleExpandTimer = -1;
      if (generation === this.rippleGeneration && this.appeared && this.visible && this.motionEnabled) {
        this.ripplePhase = 2;
      }
    }, 24);
    this.rippleResetTimer = setTimeout((): void => {
      this.rippleResetTimer = -1;
      if (generation === this.rippleGeneration) {
        this.ripplePhase = 0;
      }
    }, 620);
  }

  private loadingAnimation(): AnimateParam {
    const generation = this.loadingGeneration;
    return {
      duration: this.motionEnabled && this.visible ? 160 : 0,
      curve: Curve.EaseOut,
      onFinish: (): void => {
        // enableLoading(false) 会隐藏图形，淡出结束后再停，旧回调不能截断新一轮反馈。
        if (!this.busy && generation === this.loadingGeneration) {
          this.loadingShown = false;
        }
      }
    };
  }

  private settledRunning(): boolean {
    return this.running && !this.busy;
  }

  private showPlay(): boolean {
    return !this.running && !this.busy;
  }

  build() {
    Stack() {
      // 单次连接确认波纹：起手藏在主体下方，落定时从圆角方轮廓平滑扩散消隐。
      Column()
        .width(BUTTON_BODY_SIZE)
        .height(BUTTON_BODY_SIZE)
        .borderRadius(BUTTON_SQUIRCLE_RADIUS)
        .border({ width: 2, color: this.appStyle.palette.brandPulse })
        .backgroundColor(Color.Transparent)
        .scale({ x: this.ripplePhase === 2 ? 1.38 : 0.94, y: this.ripplePhase === 2 ? 1.38 : 0.94 })
        .opacity(this.ripplePhase === 1 ? 0.72 : 0)
        .animation({
          duration: this.ripplePhase === 2 && this.motionEnabled && this.visible ? 560 : 0,
          curve: Curve.EaseOut
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      // 连接/断开过渡呼吸环：使用对称往返脉冲，任意时刻停止都能平滑收回，无突兀跳变。
      Column()
        .width(BUTTON_HALO_SIZE)
        .height(BUTTON_HALO_SIZE)
        .borderRadius(BUTTON_HALO_CIRCLE_RADIUS)
        .backgroundColor(this.appStyle.palette.brandSoft)
        .border({ width: 1.5, color: this.appStyle.palette.brandPulse })
        .scale({ x: this.busyPulsing ? 1.1 : 0.88, y: this.busyPulsing ? 1.1 : 0.88 })
        .opacity(this.busyPulsing ? 0.85 : 0)
        .animation({
          duration: this.busyPulsing ? 720 : (this.motionEnabled && this.visible ? 220 : 0),
          curve: this.busyPulsing ? Curve.EaseInOut : Curve.EaseOut,
          iterations: this.busyPulsing ? -1 : 1,
          playMode: this.busyPulsing ? PlayMode.Alternate : PlayMode.Normal
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      // 运行态同心软晕：与主体严格等距同心（22vp + 7vp = 29vp），稳态零动画。
      Column()
        .width(BUTTON_HALO_SIZE)
        .height(BUTTON_HALO_SIZE)
        .borderRadius(this.settledRunning() ? BUTTON_HALO_SQUIRCLE_RADIUS : BUTTON_HALO_CIRCLE_RADIUS)
        .backgroundColor(this.appStyle.palette.brandSoft)
        .scale({ x: this.settledRunning() ? 1 : 0.78, y: this.settledRunning() ? 1 : 0.78 })
        .opacity(this.settledRunning() ? 1 : 0)
        .animation({
          duration: this.motionEnabled && this.visible ? 360 : 0,
          curve: this.settledRunning() ? HALO_SPRING : Curve.EaseOut
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      // 开关主体：待机为正圆、运行态弹簧形变为圆角方，过渡期稳态微缩不晃动。
      Column()
        .width(BUTTON_BODY_SIZE)
        .height(BUTTON_BODY_SIZE)
        .borderRadius(this.settledRunning() ? BUTTON_SQUIRCLE_RADIUS : BUTTON_CIRCLE_RADIUS)
        .backgroundColor(this.appStyle.palette.brand)
        .scale({ x: this.busy ? 0.92 : 1, y: this.busy ? 0.92 : 1 })
        .shadow({
          radius: this.getUIContext().vp2px(this.settledRunning() ? 14 : 10),
          color: shadowHex(this.appStyle.palette.brandPulse),
          offsetX: 0,
          offsetY: this.getUIContext().vp2px(4)
        })
        .animation({
          duration: this.motionEnabled && this.visible ? 380 : 0,
          curve: this.motionEnabled && this.visible ? MORPH_SPRING : Curve.EaseOut
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(28)
        .fontColor([this.appStyle.palette.onBrand])
        .width(28)
        .height(28)
        .translate({ x: 1.5 })
        .scale({ x: this.showPlay() ? 1 : 0.55, y: this.showPlay() ? 1 : 0.55 })
        .rotate({ angle: this.showPlay() ? 0 : -24 })
        .opacity(this.showPlay() ? 1 : 0)
        .animation({ duration: this.motionEnabled && this.visible ? 200 : 0, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(28)
        .fontColor([this.appStyle.palette.onBrand])
        .width(28)
        .height(28)
        .scale({ x: this.settledRunning() ? 1 : 0.55, y: this.settledRunning() ? 1 : 0.55 })
        .rotate({ angle: this.settledRunning() ? 0 : 24 })
        .opacity(this.settledRunning() ? 1 : 0)
        .animation({ duration: this.motionEnabled && this.visible ? 200 : 0, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      LoadingProgress()
        .width(28)
        .height(28)
        .color(this.appStyle.palette.onBrand)
        .enableLoading(this.loadingShown)
        .scale({ x: this.busy ? 1 : 0.65, y: this.busy ? 1 : 0.65 })
        .opacity(this.busy ? 1 : 0)
        .animation(this.loadingAnimation())
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .width(BUTTON_STAGE_SIZE)
    .height(BUTTON_STAGE_SIZE)
    .clip(false)
    .onAppear((): void => {
      this.appeared = true;
      this.wasSettledRunning = this.settledRunning();
      this.syncLoading();
    })
    .onDisAppear((): void => {
      this.appeared = false;
      this.busyPulsing = false;
      this.clearRipple();
    })
  }
}

class RunButtonContent implements ContentModifier<ButtonConfiguration> {
  private static readonly builder: WrappedBuilder<[ButtonConfiguration]> = wrapBuilder(runButtonContent);
  running: boolean;
  busy: boolean;
  visible: boolean;
  motionEnabled: boolean;

  constructor(running: boolean, busy: boolean, visible: boolean, motionEnabled: boolean) {
    this.running = running;
    this.busy = busy;
    this.visible = visible;
    this.motionEnabled = motionEnabled;
  }

  applyContent(): WrappedBuilder<[ButtonConfiguration]> {
    return RunButtonContent.builder;
  }
}

@Builder
function runButtonContent(configuration: ButtonConfiguration) {
  Stack() {
    RunButtonFace({
      running: (configuration.contentModifier as RunButtonContent).running,
      busy: (configuration.contentModifier as RunButtonContent).busy,
      visible: (configuration.contentModifier as RunButtonContent).visible,
      motionEnabled: (configuration.contentModifier as RunButtonContent).motionEnabled
    })
  }
    .width(BUTTON_STAGE_SIZE)
    .height(BUTTON_STAGE_SIZE)
    .clip(false)
    .gesture(TapGesture({ count: 1 }).onAction((event: GestureEvent): void => {
      if (configuration.enabled && event.fingerList.length > 0) {
        configuration.triggerClick(event.fingerList[0].localX, event.fingerList[0].localY);
      }
    }))
}

@ComponentV2
export struct DashboardRunButton {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param running: boolean = false;
  @Param busy: boolean = false;
  @Param available: boolean = false;
  @Param interactive: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param visible: boolean = false;
  @Param label: ResourceStr = '';
  @Event onToggle: () => void = () => {};
  private inViewport: boolean = false;
  private interactiveReported: boolean = false;

  @Monitor('interactive', 'visible')
  reportInteractive(): void {
    if (this.visible && this.interactive && this.inViewport && !this.interactiveReported) {
      this.interactiveReported = true;
      hilog.info(0x0A11, 'ArkClashBench', 'dashboard_interactive');
    }
  }

  build() {
    Button({ type: ButtonType.Normal })
      .id('arkclash_vpn_toggle')
      .fontFamily(this.appStyle.fontFamily)
      .contentModifier(new RunButtonContent(this.running, this.busy, this.visible, this.motionEnabled))
      .width(BUTTON_STAGE_SIZE)
      .height(BUTTON_STAGE_SIZE)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .clip(false)
      .stateEffect(false)
      .stateStyles({
        normal: {
          .scale({ x: 1, y: 1 })
          .opacity(this.available || this.running || this.busy ? 1 : 0.45)
        },
        pressed: {
          .scale({ x: this.motionEnabled ? 0.91 : 1, y: this.motionEnabled ? 0.91 : 1 })
          .opacity(0.9)
        },
        disabled: {
          .scale({ x: 1, y: 1 })
          .opacity(this.available || this.running || this.busy ? 1 : 0.45)
        }
      })
      .animation({ duration: this.motionEnabled && this.visible ? 160 : 0, curve: Curve.EaseOut })
      .enabled(this.interactive)
      .onVisibleAreaChange([0.0], (isVisible: boolean, ratio: number): void => {
        this.inViewport = isVisible && ratio > 0;
        this.reportInteractive();
      })
      .accessibilityText(uiResourceText(this.getUIContext(), this.label))
      .onClick((): void => { this.onToggle(); })
  }
}

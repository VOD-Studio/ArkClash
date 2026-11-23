import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { uiResourceText } from '../../components/ResourceText';
import { DashboardLoadingRotation } from './DashboardLoadingRotation';

const START_CURVE = curves.cubicBezierCurve(0.175, 0.885, 0.32, 1.275);
const STOP_CURVE = curves.cubicBezierCurve(0.55, 0.055, 0.675, 0.19);
const RUN_BUTTON_SHAPE = 'M54 4 C71 2 86 4 92 14 C102 31 93 58 84 77 C78 90 69 100 58 99 ' +
  'C42 97 23 84 12 70 C-1 55 -1 37 9 24 C19 10 35 5 54 4 Z';

@ComponentV2
struct RunButtonFace {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param running: boolean = false;
  @Param busy: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param visible: boolean = false;

  @Local loadingShown: boolean = false;
  private loadingGeneration: number = 0;

  aboutToAppear(): void {
    this.syncLoading();
  }

  aboutToDisappear(): void {
    this.loadingGeneration++;
    this.loadingShown = false;
  }

  @Monitor('busy', 'visible', 'motionEnabled')
  syncLoading(): void {
    this.loadingGeneration++;
    if (this.busy || !this.visible || !this.motionEnabled) {
      this.loadingShown = this.visible && this.busy;
    }
  }

  private loadingAnimation(): AnimateParam {
    const generation = this.loadingGeneration;
    return {
      duration: this.motionEnabled && this.visible ? 140 : 0,
      curve: Curve.EaseOut,
      onFinish: (): void => {
        // enableLoading(false) 会隐藏图形，淡出结束后再停，旧回调不能截断新一轮反馈。
        if (!this.busy && generation === this.loadingGeneration) {
          this.loadingShown = false;
        }
      }
    };
  }

  build() {
    Stack() {
      DashboardLoadingRotation({ active: this.busy, visible: this.visible, motionEnabled: this.motionEnabled }) {
        Shape() {
          Path().commands(RUN_BUTTON_SHAPE)
            .fill(this.appStyle.palette.brand)
            .strokeWidth(0)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(84)
        .height(84)
        .rotate({ angle: this.running ? 40 : 0 })
        .scale({ x: this.running ? 1.02 : 1, y: this.running ? 1.02 : 1 })
        .animation({ duration: this.motionEnabled && this.visible ? 450 : 0,
          curve: this.running ? START_CURVE : STOP_CURVE })
      }
      SymbolGlyph(this.running ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(30)
        .fontColor([this.appStyle.palette.onBrand])
        .width(30)
        .height(30)
        .opacity(this.busy ? 0 : 1)
        .animation({ duration: this.motionEnabled && this.visible ? 140 : 0, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
      LoadingProgress()
        .width(30)
        .height(30)
        .color(this.appStyle.palette.onBrand)
        .enableLoading(this.loadingShown)
        .opacity(this.busy ? 1 : 0)
        .animation(this.loadingAnimation())
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .width(88)
    .height(88)
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
    .width(88)
    .height(88)
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
      .width(88)
      .height(88)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .stateEffect(false)
      .stateStyles({
        normal: {
          .scale({ x: 1, y: 1 })
          .opacity(this.available || this.running || this.busy ? 1 : 0.45)
        },
        pressed: {
          .scale({ x: this.motionEnabled ? 0.92 : 1, y: this.motionEnabled ? 0.98 : 1 })
          .opacity(0.88)
        },
        disabled: {
          .scale({ x: 1, y: 1 })
          .opacity(this.available || this.running || this.busy ? 1 : 0.45)
        }
      })
      .animation({ duration: this.motionEnabled && this.visible ? 180 : 0, curve: Curve.EaseOut })
      .enabled(this.interactive)
      .onVisibleAreaChange([0.0], (isVisible: boolean, ratio: number): void => {
        this.inViewport = isVisible && ratio > 0;
        this.reportInteractive();
      })
      .accessibilityText(uiResourceText(this.getUIContext(), this.label))
      .onClick((): void => { this.onToggle(); })
  }
}

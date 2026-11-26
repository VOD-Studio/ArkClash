import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { uiResourceText } from '../../components/ResourceText';

const BUTTON_STAGE_SIZE = 82;
const BUTTON_SHAPE_SIZE = 78;
const BUTTON_ICON_SIZE = 28;
const MORPH_SPRING = curves.springMotion(0.42, 0.82);

// 原始不规则鹅卵石轮廓（1 个起点 + 6 段三次贝塞尔闭合曲线，共 38 个坐标值）。
const IRREGULAR_BUTTON_POINTS: number[] = [
  54, 4,
  71, 2, 86, 4, 92, 14,
  102, 31, 93, 58, 84, 77,
  78, 90, 69, 100, 58, 99,
  42, 97, 23, 84, 12, 70,
  -1, 55, -1, 37, 9, 24,
  19, 10, 35, 5, 54, 4
];

// 与上方 6 段锚点一一对应的等面积正圆（圆心 50,50、半径 45.5、从 -85° 顺时针每 60° 一段）。
const REGULAR_CIRCLE_POINTS: number[] = [
  53.97, 4.67,
  70.16, 6.09, 84.37, 16.04, 91.24, 30.77,
  98.11, 45.5, 96.6, 62.78, 87.27, 76.1,
  77.95, 89.41, 62.23, 96.74, 46.03, 95.33,
  29.84, 93.91, 15.63, 83.96, 8.76, 69.23,
  1.89, 54.5, 3.4, 37.22, 12.73, 23.9,
  22.05, 10.59, 37.77, 3.26, 53.97, 4.67
];

function lerpCoordinate(index: number, factor: number): string {
  const start = IRREGULAR_BUTTON_POINTS[index];
  const value = start + (REGULAR_CIRCLE_POINTS[index] - start) * factor;
  return value.toFixed(2);
}

function morphedRunButtonCommands(progress: number): string {
  const factor = Math.max(-0.08, Math.min(1.08, progress));
  let commands = `M${lerpCoordinate(0, factor)} ${lerpCoordinate(1, factor)}`;
  for (let segment = 0; segment < 6; segment++) {
    const base = 2 + segment * 6;
    commands += ` C${lerpCoordinate(base, factor)} ${lerpCoordinate(base + 1, factor)} ` +
      `${lerpCoordinate(base + 2, factor)} ${lerpCoordinate(base + 3, factor)} ` +
      `${lerpCoordinate(base + 4, factor)} ${lerpCoordinate(base + 5, factor)}`;
  }
  return `${commands} Z`;
}

// 逐帧插值 6 段三次贝塞尔控制点，让不规则轮廓与规则圆形之间连续自然形变。
@AnimatableExtend(Path)
function runButtonMorphCommands(progress: number) {
  .commands(morphedRunButtonCommands(progress))
}

@ComponentV2
struct RunButtonFace {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param running: boolean = false;
  @Param busy: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param visible: boolean = false;

  @Local private loadingShown: boolean = false;
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
      Shape() {
        Path()
          .runButtonMorphCommands(this.running ? 1 : 0)
          .fill(this.appStyle.palette.brand)
          .strokeWidth(0)
          .animation({
            duration: this.motionEnabled && this.visible ? 460 : 0,
            curve: this.motionEnabled && this.visible ? MORPH_SPRING : Curve.EaseOut
          })
      }
      .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
      .width(BUTTON_SHAPE_SIZE)
      .height(BUTTON_SHAPE_SIZE)
      .scale({ x: this.busy ? 0.93 : 1, y: this.busy ? 0.93 : 1 })
      .animation({
        duration: this.motionEnabled && this.visible ? 320 : 0,
        curve: this.motionEnabled && this.visible ? MORPH_SPRING : Curve.EaseOut
      })
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')

      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(BUTTON_ICON_SIZE)
        .fontColor([this.appStyle.palette.onBrand])
        .width(BUTTON_ICON_SIZE)
        .height(BUTTON_ICON_SIZE)
        .translate({ x: 1.5 })
        .scale({ x: this.showPlay() ? 1 : 0.55, y: this.showPlay() ? 1 : 0.55 })
        .rotate({ angle: this.showPlay() ? 0 : -24 })
        .opacity(this.showPlay() ? 1 : 0)
        .animation({ duration: this.motionEnabled && this.visible ? 200 : 0, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(BUTTON_ICON_SIZE)
        .fontColor([this.appStyle.palette.onBrand])
        .width(BUTTON_ICON_SIZE)
        .height(BUTTON_ICON_SIZE)
        .scale({ x: this.settledRunning() ? 1 : 0.55, y: this.settledRunning() ? 1 : 0.55 })
        .rotate({ angle: this.settledRunning() ? 0 : 24 })
        .opacity(this.settledRunning() ? 1 : 0)
        .animation({ duration: this.motionEnabled && this.visible ? 200 : 0, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      LoadingProgress()
        .width(BUTTON_ICON_SIZE)
        .height(BUTTON_ICON_SIZE)
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

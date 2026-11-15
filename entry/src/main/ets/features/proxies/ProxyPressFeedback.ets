import { UIContext, UIUtils } from '@kit.ArkUI';

@ObservedV2
export class ProxyPressState {
  @Trace visible: boolean = false;
  @Trace originX: number = 0;
  @Trace originY: number = 0;
  @Trace diameter: number = 0;
  @Trace inkScale: number = 0;
  @Trace inkOpacity: number = 0;
  private width: number = 0;
  private height: number = 0;
  private pressed: boolean = false;

  resize(width: number, height: number): void {
    this.width = width;
    this.height = height;
  }

  recycle(): void {
    // 回收期间 V2 已冻结，复用解冻后再清可见状态，避免吞掉 UI 刷新。
    this.pressed = false;
  }

  reset(): void {
    this.pressed = false;
    this.visible = false;
  }

  touch(event: TouchEvent, context: UIContext, motionEnabled: boolean): void {
    if (!motionEnabled) {
      this.reset();
      return;
    }
    if (event.type === TouchType.Cancel || event.touches.length > 1) {
      this.release(context, true);
      return;
    }
    const point = event.changedTouches[0] ?? event.touches[0];
    if (event.type === TouchType.Down && point !== undefined && this.width > 0 && this.height > 0) {
      this.pressed = true;
      const radius = Math.hypot(Math.max(point.x, this.width - point.x), Math.max(point.y, this.height - point.y));
      // 零时长事务中断上次反馈；扩散与淡出交给渲染侧，不占用逐帧回调。
      context.animateToImmediately({ duration: 0 }, (): void => {
        UIUtils.applySync((): void => {
          this.visible = true;
          this.originX = point.x;
          this.originY = point.y;
          this.diameter = radius * 2;
          this.inkScale = 0.04;
          this.inkOpacity = 1;
        });
      });
      context.animateTo({ duration: 360, curve: Curve.EaseOut }, (): void => {
        UIUtils.applySync((): void => { this.inkScale = 1; });
      });
    } else if (event.type === TouchType.Up) {
      this.release(context, false);
    } else if (event.type === TouchType.Move && point !== undefined &&
      Math.hypot(point.x - this.originX, point.y - this.originY) > 8) {
      this.release(context, true);
    }
  }

  private release(context: UIContext, cancelled: boolean): void {
    if (!this.pressed) {
      return;
    }
    this.pressed = false;
    context.animateTo({ duration: cancelled ? 80 : 220, delay: cancelled ? 0 : 80, curve: Curve.EaseOut }, (): void => {
      UIUtils.applySync((): void => { this.inkOpacity = 0; });
    });
  }
}

@ComponentV2
export struct ProxyPressFeedback {
  @Param @Require feedback: ProxyPressState;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.feedback.visible) {
        Column()
          .width(this.feedback.diameter)
          .height(this.feedback.diameter)
          .radialGradient({ center: ['50%', '50%'], radius: '50%',
            colors: [[$r('app.color.proxy_press_feedback'), 0], [$r('app.color.proxy_press_feedback'), 0.7],
              [Color.Transparent, 1]] })
          .position({ x: this.feedback.originX - this.feedback.diameter / 2,
            y: this.feedback.originY - this.feedback.diameter / 2 })
          .scale({ x: this.feedback.inkScale, y: this.feedback.inkScale })
          .opacity(this.feedback.inkOpacity)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }
}

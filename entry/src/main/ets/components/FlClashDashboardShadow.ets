import { DrawContext, Theme } from '@kit.ArkUI';
import { common2D, drawing } from '@kit.ArkGraphics2D';
import { resourceManager } from '@kit.LocalizationKit';

class FlClashDashboardShadowLayer {
  private readonly brush: drawing.Brush = new drawing.Brush();
  private shape: drawing.RoundRect | undefined;
  private offsetY: number = 0;
  private cssBlur: number = 0;
  private spread: number = 0;
  private color: number = 0;
  private lastWidth: number = -1;
  private lastHeight: number = -1;
  private lastDensity: number = -1;
  private lastSigma: number = -1;

  constructor() {
    this.brush.setAntiAlias(true);
  }

  configure(color: number, offsetY: number, cssBlur: number, spread: number = 0): void {
    this.color = color;
    this.offsetY = offsetY;
    this.cssBlur = cssBlur;
    this.spread = spread;
    this.brush.setColor(color);
    this.lastWidth = -1;
  }

  draw(canvas: drawing.Canvas, cardWidth: number, cardHeight: number, density: number): void {
    if ((this.color >>> 24) === 0) return;
    if (this.lastWidth !== cardWidth || this.lastHeight !== cardHeight || this.lastDensity !== density) {
      const spread = this.spread * density;
      const offsetY = this.offsetY * density;
      const rect: common2D.Rect = { left: -spread, top: offsetY - spread,
        right: cardWidth + spread, bottom: cardHeight + offsetY + spread };
      const radius = (34 + this.spread) * density;
      this.shape = new drawing.RoundRect(rect, radius, radius);
      // 对应 FlClash dashboard/style.dart 的 _blur：CSS blur≤1 不模糊，其余最终 sigma=CSS blur/2。
      const sigma = this.cssBlur <= 1 ? 0 : this.cssBlur * density / 2;
      if (sigma !== this.lastSigma) {
        this.brush.setMaskFilter(sigma > 0 ?
          drawing.MaskFilter.createBlurMaskFilter(drawing.BlurType.NORMAL, sigma) : null);
        this.lastSigma = sigma;
      }
      this.lastWidth = cardWidth;
      this.lastHeight = cardHeight;
      this.lastDensity = density;
    }
    if (this.shape === undefined) return;
    canvas.attachBrush(this.brush);
    canvas.drawRoundRect(this.shape);
    canvas.detachBrush();
  }
}

class FlClashDashboardShadowPainter extends DrawModifier {
  private readonly contact: FlClashDashboardShadowLayer = new FlClashDashboardShadowLayer();
  private readonly ambient: FlClashDashboardShadowLayer = new FlClashDashboardShadowLayer();
  private readonly diffuse: FlClashDashboardShadowLayer = new FlClashDashboardShadowLayer();
  private cardShape: drawing.RoundRect | undefined;
  private lastWidth: number = -1;
  private lastHeight: number = -1;
  private lastDensity: number = -1;
  private configured: boolean = false;

  applyTheme(dark: boolean, contactColor: number, ambientColor: number, diffuseColor: number): void {
    this.contact.configure(contactColor, dark ? 1 : 0.5, dark ? 2 : 1);
    this.ambient.configure(ambientColor, dark ? 10 : 2, dark ? 28 : 6, dark ? -6 : 0);
    this.diffuse.configure(diffuseColor, 12, 32, -6);
    this.configured = true;
    this.invalidate();
  }

  // SDK 的 drawOverlay 允许越过背景节点边界；每张卡片持有独立实例，不能复用 DrawModifier。
  drawOverlay(context: DrawContext): void {
    if (!this.configured) return;
    const logicalSize = context.size;
    const physicalSize = context.sizeInPixel;
    if (logicalSize.width <= 0 || physicalSize.width <= 0 || physicalSize.height <= 0) return;
    const density = physicalSize.width / logicalSize.width;
    if (this.lastWidth !== physicalSize.width || this.lastHeight !== physicalSize.height ||
      this.lastDensity !== density) {
      const rect: common2D.Rect = { left: 0, top: 0,
        right: physicalSize.width, bottom: physicalSize.height };
      this.cardShape = new drawing.RoundRect(rect, 34 * density, 34 * density);
      this.lastWidth = physicalSize.width;
      this.lastHeight = physicalSize.height;
      this.lastDensity = density;
    }
    if (this.cardShape === undefined) return;
    const canvas = context.canvas;
    canvas.save();
    // background builder 画在卡片底色之上，挖掉不透明卡面，避免阴影染黑内容。
    canvas.clipRoundRect(this.cardShape, drawing.ClipOp.DIFFERENCE, true);
    this.contact.draw(canvas, physicalSize.width, physicalSize.height, density);
    this.ambient.draw(canvas, physicalSize.width, physicalSize.height, density);
    this.diffuse.draw(canvas, physicalSize.width, physicalSize.height, density);
    canvas.restore();
  }
}

@ComponentV2
export struct FlClashDashboardShadow {
  private readonly painter: FlClashDashboardShadowPainter = new FlClashDashboardShadowPainter();

  aboutToAppear(): void {
    this.refreshShadow();
  }

  onWillApplyTheme(_theme: Theme): void {
    this.refreshShadow();
  }

  private refreshShadow(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return;
    const resources = context.resourceManager;
    this.painter.applyTheme(resources.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK,
      resources.getColorSync($r('app.color.dashboard_shadow_contact').id),
      resources.getColorSync($r('app.color.dashboard_shadow_ambient').id),
      resources.getColorSync($r('app.color.dashboard_shadow_diffuse').id));
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .clip(false)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
      .drawModifier(this.painter)
  }
}

import { taskpool } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { BarcodeFormat, EncodeHintType, QRCodeWriter } from '@ohos/zxing';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';

@Concurrent
function subscriptionQrPixels(source: string, side: number): ArrayBuffer {
  const hints = new Map<EncodeHintType, Object>();
  hints.set(EncodeHintType.CHARACTER_SET, 'UTF-8');
  const matrix = new QRCodeWriter().encode(source, BarcodeFormat.QR_CODE, side, side, hints);
  const pixels = new Uint32Array(side * side);
  for (let y = 0; y < side; y++) {
    for (let x = 0; x < side; x++) {
      pixels[y * side + x] = matrix.get(x, y) ? 0xff000000 : 0xffffffff;
    }
  }
  return pixels.buffer;
}

@ComponentV2
export struct ProfileQrShare {
  @Param @Require source: string;
  @Event onCopy: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private qrImage: image.PixelMap | undefined = undefined;
  @Local private failed: boolean = false;
  private rendering: boolean = false;

  aboutToAppear(): void {
    this.rendering = true;
    this.generate();
  }

  aboutToDisappear(): void {
    this.rendering = false;
    this.qrImage?.release().catch((): void => {});
    this.qrImage = undefined;
  }

  private async generate(): Promise<void> {
    const side = 768;
    try {
      const pixels = await taskpool.execute(subscriptionQrPixels, this.source, side) as ArrayBuffer;
      if (!this.rendering) { return; }
      const qr = await image.createPixelMapFromPixels(pixels, {
        size: { width: side, height: side }, srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888, alphaType: image.AlphaType.OPAQUE
      });
      if (this.rendering) { this.qrImage = qr; }
      else { await qr.release(); }
    } catch (error) {
      if (this.rendering) { this.failed = true; }
    }
  }

  build() {
    Column({ space: 16 }) {
      if (this.failed) {
        Text($r('app.string.profile_qr_share_error')).fontFamily(this.appStyle.fontFamily).fontSize(16)
          .textAlign(TextAlign.Center).fontColor($r('sys.color.font_primary'))
      } else if (this.qrImage !== undefined) {
        Image(this.qrImage).width(264).height(264).interpolation(ImageInterpolation.None)
          .accessibilityText($r('app.string.profile_qr_share'))
      } else {
        Column() { LoadingProgress().width(28).height(28).color(this.appStyle.palette.brand) }
          .width(264).height(264).justifyContent(FlexAlign.Center)
      }
      Button($r('app.string.action_copy_link')).fontFamily(this.appStyle.fontFamily)
        .buttonStyle(ButtonStyleMode.NORMAL).height(48).onClick((): void => this.onCopy())
    }
    .width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }
}

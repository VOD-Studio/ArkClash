import { AppGlyph } from '../../components/AppGlyph';

const DASHBOARD_GROUP_LETTER: RegExp = new RegExp('[\\p{L}\\p{N}]', 'u');
const DASHBOARD_GROUP_EXTEND: string = '[\\p{Grapheme_Extend}\\p{Emoji_Modifier}\\p{Mc}]';
const DASHBOARD_GROUP_PICTURE: string = '\\p{Extended_Pictographic}' + DASHBOARD_GROUP_EXTEND +
  '*(?:\\u200D\\p{Extended_Pictographic}' + DASHBOARD_GROUP_EXTEND + '*)*';
const DASHBOARD_GROUP_GRAPHEME: RegExp = new RegExp('^(?:\\r\\n|\\p{Regional_Indicator}{2}|' +
  DASHBOARD_GROUP_PICTURE + '|[^\\p{Cc}\\p{Cf}])' + DASHBOARD_GROUP_EXTEND + '*(?:\\u200D)?|^[\\s\\S]', 'u');

export function dashboardGroupMonogram(name: string): string {
  const letter = DASHBOARD_GROUP_LETTER.exec(name);
  if (letter !== null) {
    return letter[0].toUpperCase();
  }
  return DASHBOARD_GROUP_GRAPHEME.exec(name)?.[0] ?? '';
}

@ComponentV2
export struct DashboardGroupAvatar {
  @Param groupName: string = '';
  @Param iconSource: string = '';
  @Param badgeSize: number = 40;
  @Local iconLoaded: boolean = false;
  @Local iconFailed: boolean = false;

  @Computed
  get mark(): string {
    return dashboardGroupMonogram(this.groupName);
  }

  @Monitor('iconSource')
  resetImage(): void {
    this.iconLoaded = false;
    this.iconFailed = false;
  }

  @Builder
  Monogram() {
    if (this.mark !== '') {
      Text(this.mark)
        .fontSize(this.badgeSize * 0.434)
        .lineHeight(this.badgeSize * 0.434)
        .fontWeight(600)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
    } else {
      AppGlyph({ name: 'layers', iconSize: this.badgeSize * 0.49, iconColor: $r('sys.color.font_secondary') })
    }
  }

  build() {
    Stack() {
      if (!this.iconLoaded || this.iconFailed || this.iconSource === '') {
        this.Monogram()
      }
      if (this.iconSource !== '' && !this.iconFailed) {
        Image(this.iconSource)
          .width(this.badgeSize * 0.7)
          .height(this.badgeSize * 0.7)
          .objectFit(ImageFit.Contain)
          .opacity(this.iconLoaded ? 1 : 0)
          .onComplete((): void => { this.iconLoaded = true; })
          .onError((): void => { this.iconFailed = true; })
      }
    }
    .width(this.badgeSize)
    .height(this.badgeSize)
    .borderRadius(this.badgeSize * 0.35)
    .backgroundColor($r('app.color.tile_background'))
    .border({ width: this.badgeSize * 0.075, color: $r('app.color.card_background') })
    .clip(true)
    .accessibilityText(this.groupName)
  }
}

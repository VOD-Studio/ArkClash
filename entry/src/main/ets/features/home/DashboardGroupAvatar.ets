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
        .fontSize(17.36)
        .lineHeight(17.36)
        .fontWeight(600)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
    } else {
      AppGlyph({ name: 'layers', iconSize: 19.6, iconColor: $r('sys.color.font_secondary') })
    }
  }

  build() {
    Stack() {
      if (!this.iconLoaded || this.iconFailed || this.iconSource === '') {
        this.Monogram()
      }
      if (this.iconSource !== '' && !this.iconFailed) {
        Image(this.iconSource)
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
          .opacity(this.iconLoaded ? 1 : 0)
          .onComplete((): void => { this.iconLoaded = true; })
          .onError((): void => { this.iconFailed = true; })
      }
    }
    .width(40)
    .height(40)
    .borderRadius(14)
    .backgroundColor($r('app.color.tile_background'))
    .border({ width: 3, color: $r('app.color.card_background') })
    .clip(true)
    .accessibilityText(this.groupName)
  }
}

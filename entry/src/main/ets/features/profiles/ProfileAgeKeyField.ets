import { AppearanceState, appAppearance } from '../../components/AppearanceState';

@ComponentV2
export struct ProfileAgeKeyField {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require secretKey: string;
  @Event onKeyChange: (text: string) => void = (_text: string): void => {};

  build() {
    Row({ space: 16 }) {
      Text($r('app.string.profile_age_key'))
        .fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
      TextInput({ text: this.secretKey, placeholder: $r('app.string.profile_field_optional') })
        .fontFamily(this.appStyle.fontFamily)
        .type(InputType.Password).enableAutoFill(false).showPasswordIcon(false).copyOption(CopyOptions.None)
        .maxLength(4096).height(56).layoutWeight(1).fontSize(17).textAlign(TextAlign.End).padding(0)
        .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.profile_age_key'))
        .onChange((text: string): void => this.onKeyChange(text))
    }
    .padding({ left: 16, right: 16 }).width('100%')
  }
}

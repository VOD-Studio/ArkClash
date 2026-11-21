import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListSource } from '../../components/ListSource';
import { PAGE_GUTTER } from '../../components/Theme';

export interface CustomChoice {
  key: string;
  label: string;
  detail: string;
}

@ComponentV2
@ReusableV2
struct CustomChoiceRow {
  @Local private style: AppearanceState = appAppearance;
  @Param @Require entry: CustomChoice;
  @Event onChoose: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Column({ space: 2 }) {
        Text(this.entry.label).fontSize(16).fontFamily(this.style.fontFamily)
          .fontColor($r('sys.color.font_primary')).width('100%')
        if (this.entry.detail !== '') {
          Text(this.entry.detail).fontSize(13).fontFamily(this.style.fontFamily)
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }
      }.padding({ top: 8, bottom: 8 }).width('100%')
    }.width('100%').constraintSize({ minHeight: 56 }).onClick((): void => this.onChoose())
  }
}

@ComponentV2
export struct CustomProfileChoice {
  @Local private style: AppearanceState = appAppearance;
  @Param @Require options: CustomChoice[];
  @Event onChoose: (choice: CustomChoice) => void = (_choice: CustomChoice): void => {};
  @Local private query: string = '';
  private rows: ListSource<CustomChoice> = new ListSource<CustomChoice>();

  aboutToAppear(): void { this.refresh(''); }

  private refresh(query: string): void {
    this.query = query;
    const needle = query.toLowerCase().trim();
    this.rows.replace(needle === '' ? this.options : this.options.filter((option: CustomChoice): boolean =>
      option.label.toLowerCase().includes(needle) || option.detail.toLowerCase().includes(needle)));
  }

  build() {
    Column({ space: 8 }) {
      TextInput({ text: this.query, placeholder: $r('app.string.custom_search') })
        .fontFamily(this.style.fontFamily).onChange((text: string): void => this.refresh(text))
      List() {
        LazyForEach(this.rows, (entry: CustomChoice) => {
          ListItem() {
            CustomChoiceRow({ entry: entry, onChoose: (): void => this.onChoose(entry) })
          }
        }, (entry: CustomChoice): string => entry.key)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.height('100%').width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 12 })
  }
}

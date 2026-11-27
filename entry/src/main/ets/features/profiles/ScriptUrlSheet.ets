import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ENTER_OFFSET, enterMotion, NoteCard, PrimaryButton, SecondaryButton, sectionTransition,
  SHEET_CARD_RADIUS, SHEET_ROW_HEIGHT, SHEET_TILE_SIZE, SheetHeader } from '../../components/SheetParts';
import { PAGE_GUTTER } from '../../components/Theme';

const URL_INPUT_ID = 'script-url-input';

/** 链接抽屉的草稿：打开时记下原链接，用来判断有没有改动。 */
@ObservedV2
export class ScriptUrlDraft {
  readonly original: string;
  @Trace text: string;

  constructor(url: string) {
    this.original = url;
    this.text = url;
  }

  dirty(): boolean {
    return this.text.trim() !== this.original.trim();
  }
}

/**
 * 从链接导入脚本，或修改远程脚本的链接后同步：标题区、链接输入卡、同步说明和主按钮。
 * 有改动时下滑或点关闭不直接走，操作区换成「继续编辑 / 放弃修改」。
 */
@ComponentV2
export struct ScriptUrlSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require draft: ScriptUrlDraft;
  // 修改已有远程脚本时传入脚本名，标题区显示它；从链接导入时为空。
  @Param scriptName: string = '';
  @Param busy: boolean = false;
  @Param issue: ResourceStr = '';
  @Param discardRequested: boolean = false;
  @Param motion: boolean = true;
  @Event onSubmit: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Event onResume: () => void = (): void => {};
  @Event onDiscard: () => void = (): void => {};
  @Event onChange: () => void = (): void => {};
  @Local private entered: boolean = false;

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  private editing(): boolean {
    return this.scriptName !== '';
  }

  private ready(): boolean {
    return this.draft.text.trim() !== '';
  }

  private submit(): void {
    if (this.ready() && !this.busy && !this.discardRequested) {
      this.onSubmit();
    }
  }

  @Builder
  InputCard() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.link')).fontSize(20).fontColor([this.appStyle.palette.brand])
      }
      .width(SHEET_TILE_SIZE)
      .height(SHEET_TILE_SIZE)
      .borderRadius(SHEET_TILE_SIZE / 2)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 2 }) {
        Text($r('app.string.script_url'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
        // 占位给一个真实的脚本链接，比「请输入链接」更能说明要填什么。
        TextInput({ text: this.draft.text, placeholder: 'https://example.com/script.js' })
          .id(URL_INPUT_ID)
          .type(InputType.URL)
          .enterKeyType(EnterKeyType.Go)
          .fontFamily('monospace')
          .fontSize(16)
          .fontWeight(500)
          .placeholderFont({ size: 16, family: 'monospace' })
          .placeholderColor($r('sys.color.font_tertiary'))
          .caretColor(this.appStyle.palette.brand)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding(0)
          .height(26)
          .maxLength(2048)
          .onChange((text: string): void => { this.draft.text = text; this.onChange(); })
          .onSubmit((): void => this.submit())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(SHEET_ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    // 整行都能点进输入框，不必瞄准那一行字。
    .onClick((): void => { this.getUIContext().getFocusController().requestFocus(URL_INPUT_ID); })
  }

  @Builder
  Actions() {
    // 两套操作叠在同一格里交替出现，切换时不会先把高度撑成两份。
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.discardRequested) {
        Column({ space: 12 }) {
          NoteCard({ icon: $r('sys.symbol.exclamationmark_circle'), text: $r('app.string.added_rules_unsaved') })
          Row({ space: 10 }) {
            SecondaryButton({ label: $r('app.string.added_rules_resume'), onPress: (): void => this.onResume() })
              .layoutWeight(1)
            SecondaryButton({ label: $r('app.string.added_rules_discard'), danger: true,
              onPress: (): void => this.onDiscard() })
              .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
        .transition(sectionTransition(this.motion))
      } else {
        Column() {
          PrimaryButton({
            label: this.editing() ? $r('app.string.script_sync') : $r('app.string.script_import'),
            busyLabel: this.editing() ? $r('app.string.script_syncing') : $r('app.string.script_importing'),
            busy: this.busy, available: this.ready(), onPress: (): void => this.submit()
          })
        }
        .width('100%')
        .transition(sectionTransition(this.motion))
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column() {
          SheetHeader({
            icon: this.editing() ? $r('sys.symbol.link') : $r('sys.symbol.cloud_and_arrow_down'),
            heading: this.editing() ? $r('app.string.script_url_edit') : $r('app.string.script_import_url'),
            subheading: this.editing() ? this.scriptName : $r('app.string.script_import_url_hint'),
            closable: !this.busy, onClose: (): void => this.onClose()
          })
        }
        .width('100%')
        .margin({ bottom: 6 })
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : ENTER_OFFSET })
        .animation(enterMotion(this.motion, 0))
        Column() { this.InputCard() }
          .width('100%')
          .enabled(!this.busy)
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(enterMotion(this.motion, 1))
        if (this.editing()) {
          Column() {
            NoteCard({ icon: $r('sys.symbol.exclamationmark_circle'), text: $r('app.string.script_remote_edit_hint') })
          }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(enterMotion(this.motion, 2))
        }
        if (this.issue !== '') {
          Column() {
            NoteCard({ icon: $r('sys.symbol.exclamationmark_triangle'), text: this.issue, error: true })
          }
          .width('100%')
          .transition(sectionTransition(this.motion))
        }
        Column() { this.Actions() }
          .width('100%')
          .margin({ top: 4 })
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(enterMotion(this.motion, this.editing() ? 3 : 2))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .onAppear((): void => { this.entered = true; })
  }
}

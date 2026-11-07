import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { EmptyState } from '../../components/EmptyState';
import { formatBytes, formatDate, formatDateTime } from '../../components/Format';
import { animationsEnabled } from '../../components/Motion';
import { TabPage } from '../../components/TabPage';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { describeError } from './ProfileErrors';
import { ProfileEdit, ProfileItem, ProfileStore } from './Profiles';

const DAY_MS = 24 * 3600 * 1000;
const MINUTE_MS = 60 * 1000;
const HOUR_MS = 3600 * 1000;
// 7 天内到期用警告色提示（#35）。
const EXPIRY_WARN_DAYS = 7;
// 选中、按下、更新中这些状态之间的渐变。
const FADE: AnimateParam = { duration: 200, curve: Curve.EaseOut };

class PrimaryButtonModifier implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(instance: ButtonAttribute): void {
    instance
      .width('100%')
      .height(48)
      .backgroundColor($r('app.color.brand'));
  }
}

class PrimaryLabelModifier implements AttributeModifier<TextAttribute> {
  applyNormalAttribute(instance: TextAttribute): void {
    instance
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.on_brand'));
  }
}

const PRIMARY_BUTTON: PrimaryButtonModifier = new PrimaryButtonModifier();
const PRIMARY_LABEL: PrimaryLabelModifier = new PrimaryLabelModifier();

@ComponentV2
export struct ProfilesPage {
  @Param @Require store: ProfileStore;
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Param topInset: number = 0;
  // 首页的「添加订阅」会把它置为 true，打开链接输入面板。
  @Param sheetRequested: boolean = false;
  @Event onSheetHandled: () => void = () => {};
  @Local addShown: boolean = false;
  @Local draftUrl: string = '';
  @Local adding: boolean = false;
  @Local addError: string = '';
  @Local editing: ProfileItem | undefined = undefined;
  @Local editShown: boolean = false;
  @Local draftName: string = '';
  @Local draftLink: string = '';
  @Local draftAuto: boolean = true;
  @Local draftInterval: string = '';
  @Local saving: boolean = false;
  @Local editError: string = '';
  @Local now: number = Date.now();
  @Local pulse: boolean = false;
  private pulseTimer: number = -1;

  @Monitor('sheetRequested')
  onSheetRequested(): void {
    if (this.sheetRequested) {
      this.openAdd();
      this.onSheetHandled();
    }
  }

  aboutToAppear(): void {
    this.now = Date.now();
  }

  private hasSubscriptions(): boolean {
    return this.store.items.some((item: ProfileItem) => item.isSubscription);
  }

  // 标题栏右侧：全部更新、添加，固定在标题栏里，不随内容滚动。
  private menus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.hasSubscriptions()) {
      menus.push({
        content: {
          label: $r('app.string.action_update_all'),
          icon: $r('sys.symbol.arrow_clockwise'),
          isEnabled: !this.store.updatingAll,
          action: () => this.updateAll()
        }
      });
    }
    menus.push({
      content: {
        label: $r('app.string.action_add'),
        icon: $r('sys.symbol.plus'),
        action: () => this.showAddMenu()
      }
    });
    return menus;
  }

  private toast(message: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // 「+」展开两项：添加订阅、导入本地文件（#35）。
  private showAddMenu(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      buttons: [
        { text: $r('app.string.action_add_subscription'), color: $r('sys.color.font_primary') },
        { text: $r('app.string.action_import_file'), color: $r('sys.color.font_primary') }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse) => {
      if (result.index === 0) {
        this.openAdd();
      } else {
        this.importLocal();
      }
    }).catch(() => {});
  }

  private openAdd(): void {
    this.draftUrl = '';
    this.addError = '';
    this.addShown = true;
  }

  private async submitAdd(): Promise<void> {
    this.adding = true;
    this.addError = '';
    const error = await this.store.addSubscription(this.draftUrl);
    this.adding = false;
    if (error === undefined) {
      this.addShown = false;
    } else {
      this.addError = error;
    }
  }

  private async importLocal(): Promise<void> {
    const error = await this.store.importLocal();
    if (error !== undefined) {
      this.toast($r('app.string.import_failed', describeError(error)));
    }
  }

  private async select(item: ProfileItem): Promise<void> {
    // store.select 同步改掉选中标记，放进 animateTo 里，描边和勾渐变过去。
    let pending: Promise<string | undefined> = Promise.resolve(undefined);
    this.getUIContext().animateTo(FADE, () => {
      pending = this.store.select(item.id);
    });
    const error = await pending;
    if (error !== undefined) {
      // 失败留在原配置，原因用 toast 说明，不往卡片里插行（#35）。
      this.toast($r('app.string.profile_switch_failed', describeError(error)));
    }
  }

  private async update(item: ProfileItem): Promise<void> {
    const error = await this.store.update(item.id);
    this.now = Date.now();
    if (error !== undefined) {
      // 手动更新失败当场显示；原因同时留在卡片上（#35）。
      this.toast($r('app.string.download_failed', describeError(error)));
    } else {
      this.toast($r('app.string.profile_updated_toast'));
    }
  }

  private async updateAll(): Promise<void> {
    await this.store.updateAll();
    this.now = Date.now();
    this.toast($r('app.string.profiles_updated_all'));
  }

  private openEdit(item: ProfileItem): void {
    this.editing = item;
    this.draftName = item.name;
    this.draftLink = item.url;
    this.draftAuto = item.autoUpdate;
    this.draftInterval = `${item.intervalHours}`;
    this.editError = '';
    this.editShown = true;
  }

  private async submitEdit(): Promise<void> {
    const item = this.editing;
    if (item === undefined) {
      return;
    }
    const edit: ProfileEdit = {
      name: this.draftName,
      url: this.draftLink,
      autoUpdate: this.draftAuto,
      intervalHours: Number(this.draftInterval)
    };
    this.saving = true;
    this.editError = '';
    const error = await this.store.edit(item.id, edit);
    this.saving = false;
    if (error === undefined) {
      this.editShown = false;
    } else {
      this.editError = error;
    }
  }

  private async replaceFile(item: ProfileItem): Promise<void> {
    const error = await this.store.replaceLocal(item.id);
    if (error !== undefined) {
      this.editError = error;
    }
  }

  private copyLink(item: ProfileItem): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast($r('app.string.copied'));
    }).catch(() => {});
  }

  private confirmRemove(item: ProfileItem): void {
    if (!this.store.canRemove(item.id)) {
      this.toast($r('app.string.profile_in_use_hint'));
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.delete_confirm_title', item.name),
      message: $r('app.string.delete_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.action_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.action_delete'),
        fontColor: $r('app.color.status_error'),
        action: () => {
          this.store.remove(item.id);
        }
      }
    });
  }

  // 热切换进行中时，选中标记已经在目标配置上（先改界面，切换在后台进行，失败再退回）。
  private isSelected(item: ProfileItem): boolean {
    return this.store.selectedId() === item.id;
  }

  private isApplying(item: ProfileItem): boolean {
    return this.store.pending === item.id;
  }

  // 切换进行中，目标卡片的描边在品牌色和浅色之间呼吸；完成后定格成实线。
  private cardBorderColor(item: ProfileItem): ResourceColor {
    if (!this.isSelected(item)) {
      return Color.Transparent;
    }
    // 只看 pulse：切换结束时 pulse 渐变回 false，描边平滑回到实线。
    return this.pulse ? $r('app.color.brand_pulse') : $r('app.color.brand');
  }

  // pending 是在 select 的 animateTo 闭包里改的，这里同步启动的动画会被外层参数覆盖成一次性渐变，
  // 所以等选中的渐变结束再开始呼吸。
  @Monitor('store.pending')
  onPendingChange(): void {
    clearTimeout(this.pulseTimer);
    const ui = this.getUIContext();
    if (this.store.pending !== '' && animationsEnabled(ui.getHostContext())) {
      this.pulseTimer = setTimeout(() => {
        ui.animateTo({ duration: 700, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate }, () => {
          this.pulse = true;
        });
      }, FADE.duration);
    } else {
      // 新的一次动画会打断上面的无限循环。
      ui.animateTo(FADE, () => {
        this.pulse = false;
      });
    }
  }

  private relativeTime(ms: number): ResourceStr {
    const elapsed = Math.max(0, this.now - ms);
    if (elapsed < MINUTE_MS) {
      return $r('app.string.just_now');
    }
    if (elapsed < HOUR_MS) {
      return $r('app.string.minutes_ago', Math.floor(elapsed / MINUTE_MS));
    }
    if (elapsed < DAY_MS) {
      return $r('app.string.hours_ago', Math.floor(elapsed / HOUR_MS));
    }
    return $r('app.string.days_ago', Math.floor(elapsed / DAY_MS));
  }

  private usedBytes(item: ProfileItem): number {
    const usage = item.state.usage;
    return usage === undefined ? 0 : usage.upload + usage.download;
  }

  private totalBytes(item: ProfileItem): number {
    return item.state.usage?.total ?? 0;
  }

  private expireAt(item: ProfileItem): number {
    return (item.state.usage?.expire ?? 0) * 1000;
  }

  private expired(item: ProfileItem): boolean {
    return this.expireAt(item) > 0 && this.expireAt(item) <= this.now;
  }

  private exhausted(item: ProfileItem): boolean {
    return this.totalBytes(item) > 0 && this.usedBytes(item) >= this.totalBytes(item);
  }

  private daysLeft(item: ProfileItem): number {
    return Math.max(0, Math.ceil((this.expireAt(item) - this.now) / DAY_MS));
  }

  private expiringSoon(item: ProfileItem): boolean {
    return this.expireAt(item) > 0 && !this.expired(item) && this.daysLeft(item) <= EXPIRY_WARN_DAYS;
  }

  build() {
    // 一个组件只挂一个 bindSheet：添加面板挂在外层，编辑面板挂在内层。
    Column() {
      Column() {
        this.Content()
      }
      .width('100%')
      .height('100%')
      .bindSheet(this.editShown, this.EditSheet(), {
        title: { title: $r('app.string.edit_profile_title') },
        height: SheetSize.FIT_CONTENT,
        systemMaterial: sheetMaterial(),
        showClose: true,
        onDisappear: () => {
          this.editShown = false;
          this.editing = undefined;
        }
      })
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.addShown, this.AddSheet(), {
      title: { title: $r('app.string.add_subscription_title') },
      height: SheetSize.FIT_CONTENT,
      systemMaterial: sheetMaterial(),
      showClose: true,
      onDisappear: () => {
        this.addShown = false;
      }
    })
  }

  @Builder
  Content() {
    TabPage({
      title: $r('app.string.tab_profiles'),
      topInset: this.topInset,
      scroller: this.scroller,
      menus: this.menus(),
      onScrollDirection: (down: boolean) => this.onScrollDirection(down)
    }) {
      if (this.store.items.length === 0) {
        Column() {
          EmptyState({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.home_no_profile'),
            hint: $r('app.string.home_no_profile_hint'),
            actionLabel: $r('app.string.action_add_subscription'),
            onAction: () => this.openAdd()
          })
        }
        .attributeModifier(CARD)
      } else {
        ForEach(this.store.items, (item: ProfileItem) => {
          this.ProfileCard(item)
        }, (item: ProfileItem) => item.id)
      }
    }
  }

  // 选中标记：勾；切换进行中是同一位置上的转圈，两者交叉淡入淡出。
  @Builder
  SelectionMark(item: ProfileItem) {
    Stack() {
      Stack() {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(14)
          .fontColor([$r('app.color.on_brand')])
      }
      .width(24)
      .height(24)
      .borderRadius(12)
      .backgroundColor($r('app.color.brand'))
      .opacity(this.isApplying(item) ? 0 : 1)
      .animation(FADE)
      LoadingProgress()
        .width(24)
        .height(24)
        .color($r('app.color.brand'))
        .opacity(this.isApplying(item) ? 1 : 0)
        .animation(FADE)
    }
    .width(24)
    .height(24)
    .accessibilityText(this.isApplying(item) ? $r('app.string.profile_switching') : $r('app.string.profile_current'))
    .transition(TransitionEffect.OPACITY.animation(FADE))
  }

  @Builder
  Tag(text: ResourceStr, color: ResourceColor, background: ResourceColor) {
    Text(text)
      .fontSize(12)
      .fontColor(color)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .borderRadius(10)
      .backgroundColor(background)
  }

  @Builder
  MoreMenu(item: ProfileItem) {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit') })
        .onClick(() => this.openEdit(item))
      if (item.isSubscription) {
        MenuItem({ content: $r('app.string.action_copy_link') })
          .onClick(() => this.copyLink(item))
      }
      // 连接中不能删正在运行的配置：置灰并说明原因（#35）。
      MenuItem({
        content: $r('app.string.action_delete'),
        labelInfo: this.store.canRemove(item.id) ? '' : $r('app.string.profile_in_use')
      })
        .enabled(this.store.canRemove(item.id))
        .onClick(() => this.confirmRemove(item))
    }
  }

  @Builder
  ProfileCard(item: ProfileItem) {
    Column() {
      Row({ space: 8 }) {
        if (item.isSubscription) {
          this.Tag($r('app.string.profile_source_subscription'), $r('app.color.brand'), $r('app.color.brand_soft'))
        } else {
          this.Tag($r('app.string.profile_source_local'), $r('sys.color.font_secondary'), $r('app.color.track'))
        }
        Blank()
        if (this.isSelected(item)) {
          this.SelectionMark(item)
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(28)
        .height(28)
        .backgroundColor($r('app.color.tile_background'))
        .accessibilityText($r('app.string.action_more'))
        .bindMenu(this.MoreMenu(item))
      }
      .width('100%')

      Text(item.name)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })

      if (item.isSubscription && item.state.updatedAt > 0) {
        Text($r('app.string.updated_ago', this.relativeTime(item.state.updatedAt)))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
      }

      if (item.isSubscription && this.totalBytes(item) > 0) {
        this.Usage(item)
      }

      if (item.isSubscription && item.state.error !== undefined && item.state.failedAt !== undefined) {
        this.ErrorRow(item)
      }

      if (item.isSubscription) {
        Button({ type: ButtonType.Capsule }) {
          // 文字和转圈叠在同一个位置交叉淡入淡出，按钮里的内容不会挪动。
          Stack() {
            Text($r('app.string.action_update'))
              .fontSize(15)
              .fontColor($r('app.color.brand'))
              .opacity(item.updating ? 0 : 1)
              .animation(FADE)
            LoadingProgress()
              .width(22)
              .height(22)
              .color($r('app.color.brand'))
              .opacity(item.updating ? 1 : 0)
              .animation(FADE)
          }
        }
        .width('100%')
        .height(40)
        .margin({ top: 14 })
        .backgroundColor($r('app.color.brand_soft'))
        .enabled(!item.updating)
        .onClick(() => this.update(item))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    // 选中和按下只改描边、底色，并且渐变过去；描边始终占位，内容不会挪动（docs/agents/ui.md）。
    .stateStyles({
      normal: {
        .backgroundColor($r('app.color.card_background'))
      },
      pressed: {
        .backgroundColor($r('app.color.tile_background'))
      }
    })
    .animation(FADE)
    // 描边放在 .animation() 后面：它的变化只由 animateTo 驱动（选中时渐变、切换中呼吸），
    // 不被上面的隐式动画截成一次性的渐变。
    .border({
      width: 1.5,
      color: this.cardBorderColor(item),
      radius: 16
    })
    .onClick(() => this.select(item))
  }

  // 已用量和总量加进度条、到期日期；已到期或用完用错误色，7 天内到期用警告色（#35）。
  @Builder
  Usage(item: ProfileItem) {
    Column() {
      Row() {
        Text($r('app.string.usage_used', formatBytes(this.usedBytes(item)), formatBytes(this.totalBytes(item))))
          .fontSize(13)
          .fontColor(this.exhausted(item) ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
          .layoutWeight(1)
        if (this.expired(item)) {
          Text($r('app.string.usage_warn_expired'))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
        } else if (this.expiringSoon(item)) {
          Text($r('app.string.usage_warn_expiring', this.daysLeft(item)))
            .fontSize(13)
            .fontColor($r('app.color.warning'))
        } else if (this.expireAt(item) > 0) {
          Text($r('app.string.usage_expire', formatDate(this.expireAt(item))))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .width('100%')
      Progress({ value: this.usedBytes(item), total: this.totalBytes(item), type: ProgressType.Linear })
        .width('100%')
        .height(4)
        .color(this.exhausted(item) ? $r('app.color.status_error') : $r('app.color.brand'))
        .backgroundColor($r('app.color.track'))
        .margin({ top: 8 })
      if (this.exhausted(item)) {
        Text($r('app.string.usage_exhausted'))
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .margin({ top: 10 })
  }

  // 传 item 而不是文字：@Builder 按值传的参数不会随状态刷新，item 是被观察的对象。
  @Builder
  ErrorRow(item: ProfileItem) {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(14)
        .fontColor([$r('app.color.status_error')])
      Text($r('app.string.profile_update_failed', formatDateTime(item.state.failedAt ?? 0),
        describeError(item.state.error ?? '')))
        .fontSize(12)
        .fontColor($r('app.color.status_error'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor($r('app.color.error_soft'))
    .margin({ top: 10 })
  }

  @Builder
  AddSheet() {
    Column({ space: 12 }) {
      TextInput({ placeholder: $r('app.string.subscription_link'), text: this.draftUrl })
        .type(InputType.URL)
        .height(48)
        .enterKeyType(EnterKeyType.Go)
        .onChange((value: string) => {
          this.draftUrl = value;
        })
        // 键盘弹起时会挡住下面的按钮，回车直接提交。
        .onSubmit(() => {
          if (!this.adding && this.draftUrl.trim().length > 0) {
            this.submitAdd();
          }
        })
      if (this.addError !== '') {
        Text($r('app.string.download_failed', describeError(this.addError)))
          .fontSize(13)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.adding) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.on_brand'))
          }
          Text($r('app.string.action_save_download'))
            .attributeModifier(PRIMARY_LABEL)
        }
      }
      .attributeModifier(PRIMARY_BUTTON)
      .enabled(!this.adding && this.draftUrl.trim().length > 0)
      .onClick(() => this.submitAdd())
    }
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  @Builder
  EditSheet() {
    Column({ space: 12 }) {
      this.FieldLabel($r('app.string.field_name'))
      TextInput({ text: this.draftName })
        .height(48)
        .onChange((value: string) => {
          this.draftName = value;
        })
      if (this.editing?.isSubscription) {
        this.FieldLabel($r('app.string.field_link'))
        // 链接默认遮蔽，点眼睛图标显示（#35）。
        TextInput({ text: this.draftLink })
          .type(InputType.Password)
          .showPasswordIcon(true)
          .height(48)
          .onChange((value: string) => {
            this.draftLink = value;
          })
        Row() {
          Text($r('app.string.field_auto_update'))
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.draftAuto })
            .onChange((on: boolean) => {
              this.draftAuto = on;
            })
        }
        .width('100%')
        .height(48)
        if (this.draftAuto) {
          this.FieldLabel($r('app.string.field_interval'))
          TextInput({ text: this.draftInterval })
            .type(InputType.Number)
            .height(48)
            .onChange((value: string) => {
              this.draftInterval = value;
            })
        }
      } else if (this.editing !== undefined) {
        Button($r('app.string.action_replace_file'), { type: ButtonType.Capsule })
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor($r('app.color.track'))
          .enabled(!(this.editing?.updating ?? false))
          .onClick(() => {
            if (this.editing !== undefined) {
              this.replaceFile(this.editing);
            }
          })
      }
      if (this.editError !== '') {
        Text(describeError(this.editError))
          .fontSize(13)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.saving || (this.editing?.updating ?? false)) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.on_brand'))
          }
          Text($r('app.string.action_save'))
            .attributeModifier(PRIMARY_LABEL)
        }
      }
      .attributeModifier(PRIMARY_BUTTON)
      .enabled(!this.saving && this.draftName.trim().length > 0)
      .onClick(() => this.submitEdit())
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  @Builder
  FieldLabel(text: ResourceStr) {
    Text(text)
      .fontSize(13)
      .fontColor($r('sys.color.font_secondary'))
      .margin({ bottom: -4 })
  }
}

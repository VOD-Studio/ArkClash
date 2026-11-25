import { ScrollControls } from '../../components/ScrollControls';
import { common } from '@kit.AbilityKit';
import { documentFileName, pickDocumentFile } from '../../client/DocumentPicker';
import { fetchIconSet } from '../../client/IconSetDownloads';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { EmptyState } from '../../components/EmptyState';
import { IconSetGrid, IconSetThumbnail } from '../../components/IconSetGrid';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { IconSetSnapshot, ProfileIconSet } from '../../shared/profiles/IconSetModel';
import { commitIconSets, emptyIconSets, importIconSetFile, readIconSets } from '../../shared/profiles/IconSets';

class IconSetRowItem {
  readonly key: string;
  readonly set: ProfileIconSet;

  constructor(set: ProfileIconSet) {
    this.key = set.id;
    this.set = set;
  }
}

@ComponentV2
export struct IconSetsPage {
  @Param foreground: boolean = true;
  @Event onPreview: (id: string) => void = (_id: string): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private snapshot: IconSetSnapshot = emptyIconSets();
  @Local private loading: boolean = true;
  @Local private loadFailed: boolean = false;
  @Local private busy: boolean = false;
  @Local private sorting: boolean = false;
  @Local private sheetShown: boolean = false;
  @Local private deleting: boolean = false;
  @Local private current?: ProfileIconSet;
  @Local private labelDraft: string = '';
  @Local private urlDraft: string = '';
  @Local private issue: ResourceStr = '';
  @Local private discard: boolean = false;
  private shown: boolean = false;
  private rows: KeyedListSource<IconSetRowItem> = new KeyedListSource<IconSetRowItem>();

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private publish(snapshot: IconSetSnapshot): void {
    this.snapshot = snapshot;
    this.rows.replace(snapshot.sets.map((set: ProfileIconSet): IconSetRowItem => new IconSetRowItem(set)));
    if (snapshot.sets.length < 2) { this.sorting = false; }
  }

  private async load(): Promise<void> {
    if (this.busy) { return; }
    this.loading = true;
    try {
      this.publish(await readIconSets(this.context().filesDir));
      this.loadFailed = false;
    } catch (_error) { this.loadFailed = true; }
    finally { this.loading = false; }
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private errorText(error: Error): Resource {
    switch (error.message) {
      case 'icon_set_input': return $r('app.string.icon_set_input');
      case 'icon_set_invalid': return $r('app.string.icon_set_invalid');
      case 'icon_set_size': return $r('app.string.icon_set_size');
      case 'icon_set_download':
      case 'timeout': return $r('app.string.icon_set_download_error');
      case 'icon_set_conflict': return $r('app.string.icon_set_conflict');
      default: return $r('app.string.icon_set_error');
    }
  }

  private async change(operation: () => Promise<IconSetSnapshot | undefined>, message: Resource): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.issue = '';
    let refresh = false;
    try {
      const updated = await operation();
      if (updated === undefined) { return; }
      this.publish(updated);
      this.sheetShown = false;
      this.toast(message);
    } catch (error) {
      const failure = error as Error;
      refresh = failure.message === 'icon_set_conflict';
      if (this.sheetShown) { this.issue = this.errorText(failure); } else { this.toast(this.errorText(failure)); }
      this.publish(this.snapshot);
    } finally {
      this.busy = false;
      if (refresh) { await this.load(); }
    }
  }

  private importFile(): void {
    this.change(async (): Promise<IconSetSnapshot | undefined> => {
      const uri = await pickDocumentFile(this.context());
      if (uri === undefined) { return undefined; }
      return importIconSetFile(this.context().filesDir, this.snapshot, uri, documentFileName(uri));
    }, $r('app.string.icon_set_saved'));
  }

  private open(item?: ProfileIconSet, deleting: boolean = false): void {
    this.current = item;
    this.labelDraft = item?.name ?? '';
    this.urlDraft = item?.url ?? '';
    this.deleting = deleting;
    this.issue = '';
    this.discard = false;
    this.sheetShown = true;
  }

  private close(dismiss: () => void): void {
    if (this.busy) { return; }
    if (!this.deleting && (this.labelDraft !== (this.current?.name ?? '') ||
      this.urlDraft !== (this.current?.url ?? ''))) {
      this.discard = !this.discard;
      return;
    }
    dismiss();
  }

  private save(): void {
    if (this.busy) { return; }
    const item = this.current;
    const name = this.labelDraft.trim();
    const source = this.urlDraft.trim();
    const latest = this.snapshot.sets.find((entry: ProfileIconSet): boolean => entry.id === item?.id);
    if (item !== undefined && (latest === undefined || latest.name !== item.name || latest.url !== item.url)) {
      this.issue = $r('app.string.icon_set_conflict');
      return;
    }
    if (item === undefined || source !== item.url) {
      this.change((): Promise<IconSetSnapshot> =>
        fetchIconSet(this.context(), this.snapshot, source, name, item?.id), $r('app.string.icon_set_saved'));
      return;
    }
    if (name === '') {
      this.issue = $r('app.string.icon_set_input');
      return;
    }
    const result = this.snapshot.sets.map((entry: ProfileIconSet): ProfileIconSet => entry.id !== item.id ? entry :
      ({ id: entry.id, name: name, url: entry.url, updatedAt: entry.updatedAt, icons: entry.icons }));
    this.change((): Promise<IconSetSnapshot> => commitIconSets(this.context().filesDir, this.snapshot.revision, result),
      $r('app.string.icon_set_saved'));
  }

  private remove(): void {
    const id = this.current?.id ?? '';
    const items = this.snapshot.sets.filter((item: ProfileIconSet): boolean => item.id !== id);
    this.change((): Promise<IconSetSnapshot> => commitIconSets(this.context().filesDir, this.snapshot.revision, items),
      $r('app.string.icon_set_saved'));
  }

  private sync(item: ProfileIconSet): void {
    this.change((): Promise<IconSetSnapshot> =>
      fetchIconSet(this.context(), this.snapshot, item.url, '', item.id), $r('app.string.icon_set_synced'));
  }

  private move(from: number, to: number): void {
    const items = this.snapshot.sets.slice();
    if (from === to || from < 0 || to < 0 || from >= items.length || to >= items.length) { return; }
    items.splice(to, 0, items.splice(from, 1)[0]);
    this.change((): Promise<IconSetSnapshot> => commitIconSets(this.context().filesDir, this.snapshot.revision, items),
      $r('app.string.icon_set_saved'));
  }

  private back(): boolean {
    if (this.sheetShown) {
      this.close((): void => { this.sheetShown = false; });
      return true;
    }
    if (this.sorting) { this.sorting = false; return true; }
    return false;
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.icon_sets_title') })
  }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.script_import_url') }).onClick((): void => this.open())
      MenuItem({ content: $r('app.string.action_import_file') }).onClick((): void => this.importFile())
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.snapshot.sets.length > 1) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.sorting ? $r('sys.symbol.checkmark') : $r('sys.symbol.sort'))
            .fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
        .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .enabled(!this.busy && !this.loading && !this.loadFailed)
        .accessibilityText($r('app.string.profile_sort')).onClick((): void => { this.sorting = !this.sorting; })
      }
      Button({ type: ButtonType.Circle }) {
        if (this.busy && !this.sheetShown) {
          LoadingProgress().width(22).height(22).color(this.appStyle.palette.brand)
        } else {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
      }
      .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .enabled(!this.busy && !this.loading && !this.loadFailed && !this.sorting)
      .accessibilityText($r('app.string.action_add')).bindMenu(this.AddMenu)
    }.height('100%').alignItems(VerticalAlign.Center).padding({ right: PAGE_GUTTER })
  }

  @Builder
  SetList() {
    List({ space: 1 }) {
      LazyForEach(this.rows, (row: IconSetRowItem) => {
        ListItem() {
          IconSetRow({ item: row.set, first: this.snapshot.sets[0]?.id === row.key,
            last: this.snapshot.sets[this.snapshot.sets.length - 1]?.id === row.key, sorting: this.sorting,
            onPreview: (): void => this.onPreview(row.key), onOptions: (): void => this.open(row.set),
            onDelete: (): void => this.open(row.set, true), onSync: (): void => this.sync(row.set) })
        }
      }, (row: IconSetRowItem): string => row.key)
        .onMove(this.sorting && !this.busy ? (from: number, to: number): void => this.move(from, to) : undefined)
    }.width('100%').height('100%').enabled(!this.busy).scrollBar(BarState.Off)
      .cachedCount(2, true).contentStartOffset(12).contentEndOffset(24)
      .clipContent(ContentClipMode.SAFE_AREA)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  Sheet() {
    Column({ space: 12 }) {
      if (this.deleting) {
        Text($r('app.string.icon_set_delete', this.current?.name ?? '')).width('100%')
      } else {
        TextInput({ text: this.labelDraft, placeholder: this.current === undefined ?
          $r('app.string.icon_set_name_optional') : $r('app.string.field_name') })
          .width('100%').height(48).maxLength(80)
          .onChange((text: string): void => { this.labelDraft = text; this.issue = ''; })
        if (this.current === undefined || this.current.url !== '') {
          TextInput({ text: this.urlDraft, placeholder: 'https://' }).type(InputType.URL)
            .width('100%').height(48).maxLength(2048)
            .onChange((text: string): void => { this.urlDraft = text; this.issue = ''; })
        }
      }
      if (this.issue !== '') { Text(this.issue).fontSize(14).fontColor($r('app.color.status_error')).width('100%') }
      if (this.discard) {
        Text($r('app.string.added_rules_unsaved')).width('100%')
        Row({ space: 12 }) {
          Button($r('app.string.added_rules_resume')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
            .onClick((): void => { this.discard = false; })
          Button($r('app.string.added_rules_discard')).role(ButtonRole.ERROR).layoutWeight(1)
            .onClick((): void => { this.sheetShown = false; })
        }.width('100%')
      } else {
        Row({ space: 12 }) {
          Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
            .onClick((): void => this.close((): void => { this.sheetShown = false; }))
          if (this.busy) {
            LoadingProgress().width(22).height(22).layoutWeight(1).color(this.appStyle.palette.brand)
          } else if (this.deleting) {
            Button($r('app.string.action_delete')).role(ButtonRole.ERROR).layoutWeight(1)
              .onClick((): void => this.remove())
          } else {
            Button($r('app.string.action_save')).layoutWeight(1).onClick((): void => this.save())
          }
        }.width('100%')
      }
    }.width('100%').enabled(!this.busy)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 14, bottom: 24 })
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; this.load(); },
      pageHidden: (): void => { this.shown = false; },
      handleBack: (): boolean => this.back()
    }) {
      Stack() {
        if (this.loading) {
          LoadingProgress().width(30).height(30).color(this.appStyle.palette.brand)
        } else if (this.loadFailed || this.snapshot.sets.length === 0) {
          EmptyState({ icon: $r('sys.symbol.picture'),
            title: this.loadFailed ? $r('app.string.icon_set_error') : $r('app.string.icon_sets_empty'),
            actionLabel: this.loadFailed ? $r('app.string.action_retry') : '',
            onAction: (): void => { this.load(); } })
        } else {
          this.SetList()
        }
        Column().bindSheet($$this.sheetShown, this.Sheet, {
          title: { title: this.deleting ? $r('app.string.action_delete') : this.current !== undefined ?
            $r('app.string.network_options') : $r('app.string.script_import_url') },
          height: SheetSize.FIT_CONTENT, systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onWillDismiss: (action: DismissSheetAction): void => this.close((): void => action.dismiss())
        })
      }.width('100%').height('100%')
    }
  }
}

@ComponentV2
@ReusableV2
struct IconSetRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: ProfileIconSet;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param sorting: boolean = false;
  @Event onPreview: () => void = () => {};
  @Event onOptions: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Event onSync: () => void = () => {};

  @Builder
  RowMenu() {
    Menu() {
      if (this.item.url !== '') {
        MenuItem({ content: $r('app.string.rule_set_sync') }).onClick((): void => this.onSync())
      }
      MenuItem({ content: $r('app.string.network_options') }).onClick((): void => this.onOptions())
      MenuItem({ content: $r('app.string.action_delete') }).contentFontColor($r('app.color.status_error'))
        .onClick((): void => this.onDelete())
    }
  }

  @Builder
  Label() {
    Row({ space: 12 }) {
      IconSetThumbnail({ source: this.item.icons[0]?.url ?? '', edge: 32 })
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.item.name).fontSize(16).fontFamily(this.appStyle.fontFamily).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '75%' })
          Text(this.item.icons.length.toString()).fontSize(11).fontColor(this.appStyle.palette.brand)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.appStyle.palette.selectionTonal).borderRadius(6)
        }.width('100%')
        Text(this.item.url === '' ? $r('app.string.rule_set_local') : $r('app.string.rule_set_remote'))
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }

  build() {
    Row({ space: 4 }) {
      if (this.sorting) {
        Row() { this.Label() }.layoutWeight(1)
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
      } else {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          this.Label()
        }.height(62).layoutWeight(1).padding(0).backgroundColor(Color.Transparent)
          .onClick((): void => this.onPreview())
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
        }.width(40).height(40).accessibilityText($r('app.string.action_more')).bindMenu(this.RowMenu)
      }
    }.width('100%').height(64).padding({ left: 16, right: 8 })
      .backgroundColor(this.appStyle.palette.cardBackground)
      .borderRadius({ topLeft: this.first ? 22 : 0, topRight: this.first ? 22 : 0,
        bottomLeft: this.last ? 22 : 0, bottomRight: this.last ? 22 : 0 })
  }
}

@ComponentV2
export struct IconSetPreviewPage {
  @Param setId: string = '';
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private set?: ProfileIconSet;
  @Local private loading: boolean = true;
  @Local private query: string = '';

  private async load(): Promise<void> {
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const snapshot = await readIconSets(context.filesDir);
      this.set = snapshot.sets.find((item: ProfileIconSet): boolean => item.id === this.setId);
    } catch (_error) { this.set = undefined; }
    finally { this.loading = false; }
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: this.set?.name ?? $r('app.string.icon_sets_title') })
  }

  @Builder
  SearchControl() {
    if (!this.loading && this.set !== undefined) {
      TextInput({ text: this.query, placeholder: $r('app.string.icon_set_search') })
        .height(40).margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8 })
        .onChange((text: string): void => { this.query = text; })
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      pageShown: (): void => { this.load(); }
    }) {
      ScrollControls({ controls: (): void => this.SearchControl() }) {
        if (this.loading) {
          Column() { LoadingProgress().width(30).height(30).color(this.appStyle.palette.brand) }
            .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else if (this.set === undefined) {
          EmptyState({ icon: $r('sys.symbol.picture'), title: $r('app.string.icon_set_error'),
            actionLabel: $r('app.string.action_retry'), onAction: (): void => { this.load(); } }).layoutWeight(1)
        } else {
          IconSetGrid({ icons: this.set.icons, query: this.query }).layoutWeight(1)
        }
      }
    }
  }
}

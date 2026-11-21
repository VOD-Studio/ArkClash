import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { EmptyState } from '../../components/EmptyState';
import { IconSetGrid, IconSetThumbnail } from '../../components/IconSetGrid';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import {
  IconSetImage, ProfileIconSet, rankIconSetImages, validGroupIconSource, validIconSetUrl
} from '../../shared/profiles/IconSetModel';
import { readIconSets } from '../../shared/profiles/IconSets';
import { ProfileGroupIcon, profileGroupIcons, setProfileGroupIcon } from '../../shared/profiles/ProfileGroupIcons';
import { ProfileSheetHeader } from './ProfileSheetHeader';

@Concurrent
function iconPickerGroups(text: string): ProfileGroupIcon[] { return profileGroupIcons(text); }

@Concurrent
function writePickerIcon(text: string, target: ProfileGroupIcon, source: string): string {
  return setProfileGroupIcon(text, target, source);
}

@Concurrent
function recommendPickerIcons(icons: IconSetImage[], name: string): IconSetImage[] {
  return rankIconSetImages(icons, name);
}

@ComponentV2
export struct ProfileIconPicker {
  @Param @Require sourceText: string;
  @Event onApply: (text: string) => void = (_text: string): void => {};
  @Event onClose: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private loading: boolean = true;
  @Local private saving: boolean = false;
  @Local private groupOptions: SelectOption[] = [];
  @Local private setOptions: SelectOption[] = [];
  @Local private groupIndex: number = -1;
  @Local private setIndex: number = 0;
  @Local private query: string = '';
  @Local private icons: IconSetImage[] = [];
  @Local private picked: string | undefined = undefined;
  @Local private currentIcon: string = '';
  @Local private hasCurrentIcon: boolean = false;
  @Local private urlEditing: boolean = false;
  @Local private urlDraft: string = '';
  @Local private issue: ResourceStr = '';
  private groups: ProfileGroupIcon[] = [];
  private sets: ProfileIconSet[] = [];
  private allIcons: IconSetImage[] = [];
  private suggested: IconSetImage[] = [];
  private mounted: boolean = false;
  private recommendRequest: number = 0;

  aboutToAppear(): void { this.mounted = true; this.load(); }
  aboutToDisappear(): void { this.mounted = false; }

  private async load(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const groups = await taskpool.execute(iconPickerGroups, this.sourceText) as ProfileGroupIcon[];
      const library = await readIconSets(context.filesDir);
      if (!this.mounted) { return; }
      this.groups = groups;
      this.sets = library.sets;
      this.groupOptions = groups.map((group: ProfileGroupIcon): SelectOption => ({ value: group.name }));
      const seen = new Set<string>();
      for (const set of this.sets) {
        for (const icon of set.icons) {
          if (!seen.has(icon.url)) {
            this.allIcons.push(icon);
            seen.add(icon.url);
          }
        }
      }
      this.chooseGroup(groups.length === 1 ? 0 : -1);
    } catch (error) {
      if (this.mounted) { this.issue = this.errorText(error as Error); }
    } finally {
      if (this.mounted) { this.loading = false; }
    }
  }

  private chooseGroup(index: number): void {
    const request = ++this.recommendRequest;
    this.groupIndex = index;
    this.issue = '';
    this.picked = undefined;
    const group = this.groups[index];
    const source = group?.icon ?? '';
    this.hasCurrentIcon = source !== '';
    this.currentIcon = validGroupIconSource(source) ? source : '';
    this.suggested = [];
    this.setOptions = this.sets.map((set: ProfileIconSet): SelectOption => ({ value: set.name }));
    const matching = this.currentIcon === '' ? -1 : this.sets.findIndex((set: ProfileIconSet): boolean =>
      set.icons.some((icon: IconSetImage): boolean => icon.url === this.currentIcon));
    this.setIndex = Math.max(matching, 0);
    this.refreshIcons();
    if (group === undefined || this.allIcons.length === 0) { return; }
    this.recommend(request, group.name, matching);
  }

  private async recommend(request: number, name: string, matching: number): Promise<void> {
    const selected = this.setIndex;
    try {
      const suggested = await taskpool.execute(recommendPickerIcons, this.allIcons, name) as IconSetImage[];
      if (!this.mounted || request !== this.recommendRequest || suggested.length === 0) { return; }
      this.suggested = suggested;
      const recommended: SelectOption = { value: $r('app.string.icon_set_recommended') };
      this.setOptions = [recommended].concat(this.setOptions);
      this.setIndex = matching < 0 && selected === this.setIndex ? 0 : this.setIndex + 1;
      this.refreshIcons();
    } catch (_error) {
      // 仍可以浏览清单及搜索。
    }
  }

  private refreshIcons(): void {
    this.icons = this.query.trim() !== '' ? this.allIcons :
      this.suggested.length > 0 && this.setIndex === 0 ? this.suggested :
        this.sets[this.setIndex - (this.suggested.length > 0 ? 1 : 0)]?.icons ?? [];
  }

  private errorText(error: Error): ResourceStr {
    switch (error.message) {
      case 'icon_set_yaml': return $r('app.string.proxy_filter_bad_yaml');
      case 'icon_set_target': return $r('app.string.icon_set_target');
      case 'icon_set_input': return $r('app.string.icon_set_input');
      default: return $r('app.string.icon_set_error');
    }
  }

  private chooseUrl(): void {
    if (!this.urlEditing) {
      const current = this.picked ?? this.currentIcon;
      this.urlDraft = validIconSetUrl(current) ? current : '';
    }
    this.urlEditing = !this.urlEditing;
    this.issue = '';
  }

  private async apply(): Promise<void> {
    const selected = this.groups[this.groupIndex];
    if (selected === undefined || this.saving || this.loading) { return; }
    const source = this.urlEditing ? this.urlDraft.trim() : this.picked;
    if (source === undefined) { return; }
    if (this.urlEditing && !validIconSetUrl(source)) {
      this.issue = $r('app.string.icon_set_input');
      return;
    }
    this.saving = true;
    try {
      const updated = await taskpool.execute(writePickerIcon, this.sourceText, selected, source) as string;
      if (this.mounted) { this.onApply(updated); }
    } catch (error) {
      if (this.mounted) { this.issue = this.errorText(error as Error); }
    } finally {
      if (this.mounted) { this.saving = false; }
    }
  }

  @Builder
  HeaderActions() {
    if (this.groups.length > 0) {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.link')).fontSize(HEADER_ICON_SIZE)
          .fontColor([this.urlEditing ? this.appStyle.palette.brand : $r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .enabled(!this.saving).accessibilityText($r('app.string.icon_set_icon_url'))
      .onClick((): void => this.chooseUrl())
    }
  }

  @Builder
  Choices() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Select(this.groupOptions).selected(this.groupIndex)
          .value(this.groupOptions[this.groupIndex]?.value ?? $r('app.string.icon_set_choose_group'))
          .constraintSize({ maxWidth: '74%' })
          .onSelect((index: number): void => this.chooseGroup(index))
        if (this.hasCurrentIcon && !this.urlEditing) {
          IconSetThumbnail({ source: this.picked ?? this.currentIcon, edge: 28 })
          Button($r('app.string.icon_set_remove_icon')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.picked !== '').onClick((): void => { this.picked = ''; this.issue = ''; })
        }
      }.width('100%')
      if (this.urlEditing) {
        TextInput({ text: this.urlDraft, placeholder: 'https://' }).type(InputType.URL).height(48).maxLength(2048)
          .onChange((source: string): void => { this.urlDraft = source; this.issue = ''; })
      } else if (this.setOptions.length > 0) {
        TextInput({ text: this.query, placeholder: $r('app.string.icon_set_search') })
          .height(40).onChange((text: string): void => { this.query = text; this.refreshIcons(); })
        if (this.query.trim() === '') {
          Select(this.setOptions).selected(this.setIndex).value(this.setOptions[this.setIndex]?.value ?? '')
            .onSelect((index: number): void => { this.setIndex = index; this.refreshIcons(); })
        }
      }
      if (this.issue !== '') { Text(this.issue).fontSize(14).fontColor($r('app.color.status_error')).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(!this.saving)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12 })
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: $r('app.string.icon_set_choose_icon'), saving: this.saving,
        canSave: !this.loading && this.groupIndex >= 0 && (this.urlEditing ? this.urlDraft.trim() !== '' :
          this.picked !== undefined), actions: (): void => this.HeaderActions(),
        onSave: (): void => { this.apply(); }, onClose: (): void => this.onClose() })
      if (this.loading) {
        Column() { LoadingProgress().width(28).height(28).color(this.appStyle.palette.brand) }
          .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.groups.length === 0) {
        EmptyState({ icon: $r('sys.symbol.picture'), title: this.issue !== '' ? this.issue :
          $r('app.string.icon_set_no_groups') }).layoutWeight(1)
      } else {
        this.Choices()
        if (!this.urlEditing) {
          IconSetGrid({ icons: this.icons, query: this.query, selected: this.picked ?? this.currentIcon,
            selectable: true, onPick: (icon: IconSetImage): void => { this.picked = icon.url; this.issue = ''; } })
            .layoutWeight(1).enabled(!this.saving)
        }
      }
    }.height('100%').width('100%')
  }
}

import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { ProxyFilterPreset, readProxyFilters } from '../../shared/profiles/ProxyFilters';
import {
  filterIntoYaml, filterTargets, ProxyFilterField, ProxyFilterTarget
} from '../../shared/profiles/ProxyFilterYaml';
import { ProfileSheetHeader } from './ProfileSheetHeader';

@Concurrent
function readTargetsForPicker(text: string): ProxyFilterTarget[] {
  return filterTargets(text);
}

@Concurrent
function applyFilterForPicker(text: string, target: ProxyFilterTarget, field: ProxyFilterField,
  expression: string): string {
  return filterIntoYaml(text, target, field, expression);
}

const PROFILE_FILTER_FIELD_OPTIONS: SelectOption[] = [
  { value: $r('app.string.proxy_filter_include') },
  { value: $r('app.string.proxy_filter_exclude') }
];

@ComponentV2
export struct ProfileFilterPicker {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require sourceText: string;
  @Event onApply: (updated: string) => void = (_updated: string): void => {};
  @Event onClose: () => void = (): void => {};
  @Local private loading: boolean = true;
  @Local private saving: boolean = false;
  @Local private targetOptions: SelectOption[] = [];
  @Local private presetOptions: SelectOption[] = [];
  @Local private targetIndex: number = -1;
  @Local private presetIndex: number = -1;
  @Local private fieldIndex: number = 0;
  @Local private issue: ResourceStr = '';
  private targets: ProxyFilterTarget[] = [];
  private presets: ProxyFilterPreset[] = [];
  private mounted: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.load();
  }

  aboutToDisappear(): void { this.mounted = false; }

  private async load(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const targets = await taskpool.execute(readTargetsForPicker, this.sourceText) as ProxyFilterTarget[];
      const snapshot = await readProxyFilters(context.filesDir);
      if (!this.mounted) { return; }
      this.targets = targets;
      this.presets = snapshot.presets;
      this.targetOptions = targets.map((target: ProxyFilterTarget): SelectOption => ({
        value: target.kind === 'group' ? $r('app.string.proxy_filter_group_choice', target.name) :
          $r('app.string.proxy_filter_provider_choice', target.name)
      }));
      this.presetOptions = this.presets.map((preset: ProxyFilterPreset): SelectOption => ({ value: preset.label }));
      if (this.targets.length === 0) { this.issue = $r('app.string.proxy_filter_no_targets'); }
      else if (this.presets.length === 0) { this.issue = $r('app.string.proxy_filter_empty'); }
    } catch (error) {
      if (this.mounted) {
        this.issue = (error as Error).message === 'proxy_filter_yaml' ?
          $r('app.string.proxy_filter_bad_yaml') : $r('app.string.proxy_filter_error');
      }
    } finally {
      if (this.mounted) { this.loading = false; }
    }
  }

  private async apply(): Promise<void> {
    const target = this.targets[this.targetIndex];
    const preset = this.presets[this.presetIndex];
    if (this.loading || this.saving || target === undefined || preset === undefined) { return; }
    const field: ProxyFilterField = this.fieldIndex === 0 ? 'filter' : 'exclude-filter';
    this.saving = true;
    this.issue = '';
    try {
      const updated = await taskpool.execute(applyFilterForPicker, this.sourceText, target, field, preset.expression) as string;
      if (!this.mounted) { return; }
      if (updated === this.sourceText) {
        this.issue = $r('app.string.proxy_filter_already_present');
      } else {
        this.onApply(updated);
      }
    } catch (_error) {
      if (this.mounted) { this.issue = $r('app.string.proxy_filter_bad_target'); }
    } finally {
      if (this.mounted) { this.saving = false; }
    }
  }

  @Builder
  Fields() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.proxy_filter_target')).fontSize(16).layoutWeight(1)
        Select(this.targetOptions).selected(this.targetIndex)
          .value(this.targetOptions[this.targetIndex]?.value ?? $r('app.string.proxy_filter_choose_target'))
          .constraintSize({ maxWidth: '70%' })
          .onSelect((index: number): void => { this.targetIndex = index; this.issue = ''; })
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
      Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      Row({ space: 8 }) {
        Text($r('app.string.proxy_filter_field')).fontSize(16).layoutWeight(1)
        Select(PROFILE_FILTER_FIELD_OPTIONS).selected(this.fieldIndex)
          .value(PROFILE_FILTER_FIELD_OPTIONS[this.fieldIndex]?.value ?? '')
          .constraintSize({ maxWidth: '70%' })
          .onSelect((index: number): void => { this.fieldIndex = index; this.issue = ''; })
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
      Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      Row({ space: 8 }) {
        Text($r('app.string.proxy_filters_title')).fontSize(16).layoutWeight(1)
        Select(this.presetOptions).selected(this.presetIndex)
          .value(this.presetOptions[this.presetIndex]?.value ?? $r('app.string.proxy_filter_choose_preset'))
          .constraintSize({ maxWidth: '70%' })
          .onSelect((index: number): void => { this.presetIndex = index; this.issue = ''; })
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    }.width('100%').enabled(!this.saving).backgroundColor(this.appStyle.palette.cardBackground).borderRadius(16)
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: $r('app.string.proxy_filter_insert'), saving: this.saving,
        confirmLabel: $r('app.string.proxy_filter_insert'),
        canSave: !this.loading && this.targetIndex >= 0 && this.presetIndex >= 0,
        onSave: (): void => { this.apply(); }, onClose: (): void => this.onClose() })
      Scroll() {
        Column({ space: 12 }) {
          if (this.loading) {
            LoadingProgress().width(28).height(28).color(this.appStyle.palette.brand)
          } else if (this.targetOptions.length > 0 && this.presetOptions.length > 0) {
            this.Fields()
          }
          if (this.presetIndex >= 0) {
            Text(this.presets[this.presetIndex]?.expression ?? '').fontFamily('monospace').fontSize(13)
              .fontColor(this.appStyle.palette.brand).width('100%')
          }
          if (this.issue !== '') {
            Text(this.issue).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Center)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.height('100%').width('100%')
  }
}

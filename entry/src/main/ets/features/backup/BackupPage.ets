import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appAppearance, AppearanceState } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { ListRow } from '../../components/ListRow';
import { PAGE_GUTTER } from '../../components/Theme';
import {
  backupDateName, BackupDav, BackupDestination, BackupPhase, BackupPlan, BackupPolicy, BackupScope, BackupSettings,
  emptyBackupDav
} from '../../shared/backup/BackupModel';
import {
  applySavedBackup, BackupControl, chooseBackupFile, chooseBackupTarget, exportBackup, probeBackupDav,
  readBackupSettings, restoreBackup, validBackupDav, writeBackupSettings
} from '../../client/BackupService';

type BackupPrompt = 'account' | 'export' | 'restore' | 'overwrite' | 'unbind';
type BackupLinkState = 'idle' | 'checking' | 'ready' | 'failed';

let cachedBackupSettings: BackupSettings | undefined = undefined;

@ComponentV2
export struct BackupPage {
  @Event onChanged: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private settings: BackupSettings = cachedBackupSettings ?? { policy: 'merge' };
  @Local private configReady: boolean = cachedBackupSettings !== undefined;
  @Local private draft: BackupDav = emptyBackupDav();
  @Local private busy: boolean = false;
  @Local private restoring: boolean = false;
  @Local private canceled: boolean = false;
  @Local private operationPhase: BackupPhase = 'idle';
  @Local private linkState: BackupLinkState = 'idle';
  @Local private linkError: string = '';
  @Local private pendingApply: boolean = false;
  @Local private sheetVisible: boolean = false;
  @Local private prompt: BackupPrompt = 'account';
  @Local private target: BackupDestination = 'local';
  @Local private removed: number = 0;
  @Local private removedNames: string = '';
  private probeGeneration: number = 0;
  private visible: boolean = false;
  private afterSheet?: () => void;
  private answerOverwrite?: (choice: boolean) => void;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private notify(label: ResourceStr): void {
    if (this.visible) { this.getUIContext().getPromptAction().showToast({ message: label }); }
  }

  private async load(test: boolean): Promise<void> {
    try {
      const loaded = await readBackupSettings(this.context().filesDir);
      cachedBackupSettings = loaded;
      this.settings = loaded;
      this.configReady = true;
      if (test) { this.probe(); }
    } catch (_error) {
      if (cachedBackupSettings === undefined) {
        this.notify($r('app.string.backup_error_io'));
      }
    }
  }

  private errorText(message: string): ResourceStr {
    if (/^backup_dav_http_[0-9]{3}$/.test(message)) {
      return $r('app.string.backup_error_http', Number(message.slice(-3)));
    }
    switch (message) {
      case 'backup_invalid': return $r('app.string.backup_error_invalid');
      case 'backup_version': return $r('app.string.backup_error_version');
      case 'backup_limit': return $r('app.string.backup_error_limit');
      case 'backup_changed': return $r('app.string.backup_error_conflict');
      case 'backup_dav_settings': return $r('app.string.backup_error_dav_settings');
      case 'backup_dav_network': return $r('app.string.backup_error_dav_network');
      case 'backup_dav_response': return $r('app.string.backup_error_dav_response');
      default: return $r('app.string.backup_error_io');
    }
  }

  private async probe(): Promise<void> {
    const connection = this.settings.dav;
    const generation = ++this.probeGeneration;
    this.linkError = '';
    if (connection === undefined || !this.visible) {
      this.linkState = 'idle';
      return;
    }
    this.linkState = 'checking';
    try {
      await probeBackupDav(this.context(), connection);
      if (generation === this.probeGeneration) { this.linkState = 'ready'; }
    } catch (error) {
      if (generation === this.probeGeneration) {
        this.linkError = (error as Error).message;
        this.linkState = 'failed';
      }
    }
  }

  private async saveSettings(next: BackupSettings, retest: boolean = false): Promise<void> {
    this.busy = true;
    try {
      await writeBackupSettings(this.context().filesDir, next);
      cachedBackupSettings = next;
      this.settings = next;
      if (retest) { this.probe(); }
    } catch (error) {
      this.notify(this.errorText((error as Error).message));
    } finally { this.busy = false; }
  }

  private editAccount(): void {
    const saved = this.settings.dav;
    this.draft = saved === undefined ? emptyBackupDav() :
      { address: saved.address, username: saved.username, password: saved.password, fileName: saved.fileName };
    this.show('account');
  }

  private storeAccount(): void {
    const account: BackupDav = {
      address: this.draft.address.trim(), username: this.draft.username.trim(),
      password: this.draft.password, fileName: this.draft.fileName.trim()
    };
    if (!validBackupDav(account)) {
      this.notify($r('app.string.backup_error_dav_settings'));
      return;
    }
    const before = this.settings.dav;
    const retest = before?.address !== account.address || before.username !== account.username ||
      before.password !== account.password;
    this.dismiss((): void => { this.saveSettings({ dav: account, policy: this.settings.policy }, retest); });
  }

  private show(prompt: BackupPrompt): void {
    this.prompt = prompt;
    this.sheetVisible = true;
  }

  private dismiss(next: () => void): void {
    this.afterSheet = next;
    this.sheetVisible = false;
  }

  private sheetClosed(): void {
    const next = this.afterSheet;
    this.afterSheet = undefined;
    if (next !== undefined) { next(); }
    else { this.finishOverwrite(false); }
  }

  private finishOverwrite(choice: boolean): void {
    const answer = this.answerOverwrite;
    this.answerOverwrite = undefined;
    answer?.(choice);
  }

  private confirmOverwrite(plan: BackupPlan): Promise<boolean> {
    if (this.canceled || !this.visible) { return Promise.resolve(false); }
    return new Promise<boolean>((resolve: (choice: boolean) => void): void => {
      this.answerOverwrite = resolve;
      this.removed = plan.removed;
      this.removedNames = (plan.removedNames ?? []).join('、');
      this.show('overwrite');
    });
  }

  private operate(destination: BackupDestination, restoring: boolean): void {
    this.target = destination;
    this.show(restoring ? 'restore' : 'export');
  }

  private async run(scope: BackupScope, restore: boolean): Promise<void> {
    this.canceled = false;
    this.busy = true;
    this.restoring = restore;
    this.operationPhase = 'idle';
    const target = this.target;
    const dav = this.settings.dav;
    const policy = this.settings.policy;
    const context = this.context();
    const control: BackupControl = {
      phase: (current: BackupPhase): void => { this.operationPhase = current; },
      canceled: (): boolean => this.canceled
    };
    try {
      if (restore) {
        const file = target === 'local' ? await chooseBackupFile(context) : '';
        if (file === undefined) { return; }
        const outcome = await restoreBackup(context, target, scope, policy, file, dav, control,
          (plan: BackupPlan): Promise<boolean> => this.confirmOverwrite(plan));
        if (outcome.canceled) { return; }
        if (!outcome.plan?.changes && !outcome.plan?.settings) {
          this.notify($r('app.string.backup_empty'));
          return;
        }
        this.pendingApply = outcome.pendingApply;
        this.onChanged();
        await this.load(true);
        this.notify(this.pendingApply ? $r('app.string.backup_restore_pending') : $r('app.string.backup_restored'));
      } else {
        const saved = await exportBackup(context, target, scope, dav, control,
          (): Promise<string | undefined> => chooseBackupTarget(context, backupDateName(new Date())));
        if (saved) { this.notify($r('app.string.backup_exported')); }
      }
    } catch (error) {
      if ((error as Error).message !== 'backup_canceled') {
        hilog.warn(0xD000, 'ArkClashBackup', '备份阶段 %{public}s 未完成 %{public}d',
          this.operationPhase, (error as BusinessError).code ?? 0);
        this.notify(this.errorText((error as Error).message));
      }
    } finally {
      this.busy = false;
      this.operationPhase = 'idle';
      this.restoring = false;
    }
  }

  private async retryApply(): Promise<void> {
    this.busy = true;
    try {
      await applySavedBackup(this.context());
      this.pendingApply = false;
      this.onChanged();
      this.notify($r('app.string.backup_restored'));
    } catch (_error) {
      this.notify($r('app.string.backup_restore_pending'));
    } finally { this.busy = false; }
  }

  private phaseText(): ResourceStr {
    switch (this.operationPhase) {
      case 'snapshot': return $r('app.string.backup_phase_snapshot');
      case 'pack': return $r('app.string.backup_phase_pack');
      case 'transfer': return this.restoring ? $r('app.string.backup_phase_read') : $r('app.string.backup_phase_write');
      case 'unpack': return $r('app.string.backup_phase_unpack');
      case 'validate': return $r('app.string.backup_phase_validate');
      case 'commit': return $r('app.string.backup_phase_commit');
      case 'apply': return $r('app.string.backup_phase_apply');
      default: return '';
    }
  }

  private statusText(): ResourceStr {
    switch (this.linkState) {
      case 'checking': return $r('app.string.backup_checking');
      case 'ready': return $r('app.string.backup_connected');
      case 'failed': return this.errorText(this.linkError);
      default: return '';
    }
  }

  private sheetTitle(): ResourceStr {
    switch (this.prompt) {
      case 'account': return $r('app.string.backup_remote');
      case 'export': return $r('app.string.backup_export');
      case 'restore': return $r('app.string.backup_restore');
      case 'overwrite': return $r('app.string.backup_replace');
      case 'unbind': return $r('app.string.backup_unbind');
    }
  }

  @Builder
  Header() { DestinationTitle({ titleText: $r('app.string.backup_title') }) }

  @Builder
  Heading(title: ResourceStr) {
    Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
      .width('100%').textAlign(TextAlign.Start).padding({ left: 12 })
  }

  @Builder
  Remote() {
    this.Heading($r('app.string.backup_remote'))
    Column() {
      if (this.settings.dav === undefined) {
        ListRow({ title: $r('app.string.backup_bind'), onTap: (): void => this.editAccount() })
      } else {
        ListRow({ title: this.settings.dav.username, value: this.statusText(), onTap: (): void => this.editAccount() })
        ListRow({ title: $r('app.string.backup_filename'), value: this.settings.dav.fileName,
          onTap: (): void => this.editAccount() })
        ListRow({ title: $r('app.string.backup_export'), onTap: (): void => this.operate('dav', false) })
        ListRow({ title: $r('app.string.backup_restore'), onTap: (): void => this.operate('dav', true) })
        ListRow({ title: $r('app.string.backup_unbind'), onTap: (): void => this.show('unbind') })
      }
    }.width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22).clip(true)
      .enabled(this.configReady && !this.busy)
    if (this.settings.dav === undefined) {
      Text($r('app.string.backup_remote_hint')).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%').textAlign(TextAlign.Start).padding({ left: 12 })
    }
  }

  @Builder
  Local() {
    this.Heading($r('app.string.backup_local'))
    Column() {
      ListRow({ title: $r('app.string.backup_export'), onTap: (): void => this.operate('local', false) })
      ListRow({ title: $r('app.string.backup_restore'), onTap: (): void => this.operate('local', true) })
    }.width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22).clip(true)
      .enabled(this.configReady && !this.busy)
  }

  @Builder
  Policy() {
    this.Heading($r('app.string.backup_policy'))
    Column() {
      this.PolicyRow('merge', $r('app.string.backup_merge'))
      this.PolicyRow('replace', $r('app.string.backup_replace'))
    }.width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22).clip(true)
      .enabled(this.configReady && !this.busy)
  }

  @Builder
  PolicyRow(policy: BackupPolicy, label: ResourceStr) {
    ListRow({ title: label, value: this.settings.policy === policy ? $r('app.string.backup_selected') : '',
      chevron: false, onTap: (): void => {
        if (this.settings.policy !== policy) { this.saveSettings({ dav: this.settings.dav, policy: policy }); }
      } })
  }

  @Builder
  Field(label: ResourceStr, text: string, kind: InputType, max: number, changed: (text: string) => void) {
    Text(label).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
    TextInput({ text: text, placeholder: label })
      .type(kind).maxLength(max).width('100%')
      .onChange((current: string): void => changed(current))
  }

  @Builder
  AccountForm() {
    this.Field($r('app.string.backup_address'), this.draft.address, InputType.URL, 2048,
      (text: string): void => { this.draft.address = text; })
    this.Field($r('app.string.backup_username'), this.draft.username, InputType.Normal, 128,
      (text: string): void => { this.draft.username = text; })
    this.Field($r('app.string.backup_password'), this.draft.password, InputType.Password, 4096,
      (text: string): void => { this.draft.password = text; })
    this.Field($r('app.string.backup_filename'), this.draft.fileName, InputType.Normal, 255,
      (text: string): void => { this.draft.fileName = text; })
    Button($r('app.string.backup_save')).width('100%').onClick((): void => this.storeAccount())
  }

  @Builder
  ScopePicker() {
    Text(this.prompt === 'restore' ? $r('app.string.backup_restore_hint') : $r('app.string.backup_sensitive'))
      .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
    Button($r('app.string.backup_profiles')).width('100%')
      .onClick((): void => this.selectScope('profiles'))
    Button($r('app.string.backup_all')).width('100%')
      .onClick((): void => this.selectScope('all'))
  }

  private selectScope(scope: BackupScope): void {
    const restore = this.prompt === 'restore';
    this.dismiss((): void => { this.run(scope, restore); });
  }

  @Builder
  Confirmation() {
    Text(this.prompt === 'overwrite' ? $r('app.string.backup_confirm_overwrite', this.removed) :
      $r('app.string.backup_confirm_unbind')).fontSize(15).width('100%')
    if (this.prompt === 'overwrite' && this.removedNames !== '') {
      Text(this.removedNames).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    Button(this.prompt === 'overwrite' ? $r('app.string.backup_replace') : $r('app.string.backup_unbind'),
      { role: ButtonRole.ERROR }).width('100%').onClick((): void => {
      const overwrite = this.prompt === 'overwrite';
      this.dismiss((): void => {
        if (overwrite) { this.finishOverwrite(true); }
        else { this.saveSettings({ policy: this.settings.policy }, true); }
      });
    })
    Button($r('app.string.action_cancel'), { buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%').onClick((): void => { this.sheetVisible = false; })
  }

  @Builder
  Sheet() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.prompt === 'account') { this.AccountForm() }
        else if (this.prompt === 'export' || this.prompt === 'restore') { this.ScopePicker() }
        else { this.Confirmation() }
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
    }.width('100%').scrollBar(BarState.Off)
  }

  build() {
    ScrollDestination({
      heading: (): void => this.Header(),
      pageShown: (): void => { this.visible = true; this.load(true); },
      pageHidden: (): void => { this.visible = false; ++this.probeGeneration; }
    }) {
      Scroll() {
        Column({ space: 10 }) {
          this.Remote()
          Blank().height(8)
          this.Local()
          Blank().height(8)
          this.Policy()
          if (this.operationPhase !== 'idle') {
            Row({ space: 8 }) {
              LoadingProgress().width(22).height(22)
              Text(this.phaseText()).fontSize(15).layoutWeight(1)
              if (!this.canceled && (this.operationPhase === 'pack' || this.operationPhase === 'snapshot' ||
                this.restoring && this.operationPhase !== 'commit' && this.operationPhase !== 'apply')) {
                Button($r('app.string.action_cancel'), { buttonStyle: ButtonStyleMode.TEXTUAL })
                  .onClick((): void => { this.canceled = true; })
              }
            }.padding(12).width('100%')
          }
          if (this.pendingApply) {
            ListRow({ title: $r('app.string.backup_retry_apply'), onTap: (): void => { this.retryApply(); } }).enabled(!this.busy)
          }
          if (!this.configReady && !this.busy) {
            Button($r('app.string.action_retry')).onClick((): void => { this.load(true); })
          }
        }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }
      .width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
      .clipContent(ContentClipMode.SAFE_AREA)
      .bindSheet($$this.sheetVisible, this.Sheet, { height: this.prompt === 'account' ? SheetSize.LARGE : SheetSize.MEDIUM,
        title: { title: this.sheetTitle() }, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
        onDisappear: (): void => this.sheetClosed() })
    }
  }
}

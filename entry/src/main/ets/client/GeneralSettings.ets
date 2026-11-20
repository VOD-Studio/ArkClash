import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  checkedGeneralSettings, defaultGeneralSettings, GeneralSettings, GENERAL_SETTINGS_FILE
} from '../shared/GeneralSettings';
import { newId } from '../shared/profiles/Store';
import { ProfileSettingsFile, readProfileSettings, saveProfileSettings } from './ProfileSettingsFile';

const generalFile: ProfileSettingsFile<GeneralSettings> = {
  fileName: GENERAL_SETTINGS_FILE,
  endpoint: '/arkclash/general/settings',
  errorPrefix: 'general_settings',
  defaults: defaultGeneralSettings,
  checked: checkedGeneralSettings
};

@ObservedV2
export class GeneralSettingsState {
  @Trace saved: GeneralSettings = defaultGeneralSettings();
  @Trace loaded: boolean = false;
  private generation: number = 0;

  async load(context: common.UIAbilityContext): Promise<void> {
    const generation = ++this.generation;
    const loaded = await readProfileSettings<GeneralSettings>(context.filesDir, generalFile);
    if (loaded.closeConnections === undefined) {
      const store = await preferences.getPreferences(context, { name: 'settings' });
      loaded.closeConnections = await store.get('closeConnections', true) as boolean;
    }
    if (generation === this.generation) {
      this.saved = loaded;
      this.loaded = true;
    }
  }

  async save(context: common.UIAbilityContext, draft: GeneralSettings): Promise<void> {
    const generation = ++this.generation;
    const expected = draft.revision;
    draft.revision = newId('g');
    const saved = await saveProfileSettings<GeneralSettings>(context, generalFile, expected, draft);
    if (generation === this.generation) {
      this.saved = saved;
      this.loaded = true;
    }
  }
}

export const generalSettingsState: GeneralSettingsState = new GeneralSettingsState();

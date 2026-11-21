import { isAlias, isScalar, ToJSOptions } from 'yaml';
import { validGroupIconSource } from './IconSetModel';
import {
  ProfileYamlGroup, ProfileYamlMapping, profileYamlGroup, profileYamlGroups, readProfileYaml, writeProfileYamlField
} from './ProfileYamlFields';

export interface ProfileGroupIcon {
  name: string;
  index: number;
  icon: string;
}

export function profileGroupIcons(text: string): ProfileGroupIcon[] {
  const document = readProfileYaml(text, 'icon_set_yaml');
  const root = document.contents as ProfileYamlMapping;
  const options: ToJSOptions = { maxAliasCount: 100 };
  const plain = document.toJS(options) as Record<string, Object>;
  const groups = plain['proxy-groups'] as Record<string, Object>[] | undefined;
  return profileYamlGroups(root).map((group: ProfileYamlGroup): ProfileGroupIcon => {
    const source = groups?.[group.index]?.['icon'];
    return { name: group.name, index: group.index, icon: typeof source === 'string' ? source : '' };
  });
}

export function setProfileGroupIcon(text: string, target: ProfileGroupIcon, source: string): string {
  if (source !== '' && !validGroupIconSource(source)) { throw new Error('icon_set_input'); }
  const document = readProfileYaml(text, 'icon_set_yaml');
  const key: ProfileYamlGroup = { name: target.name, index: target.index };
  const group = profileYamlGroup(document.contents as ProfileYamlMapping, key);
  if (group === undefined || group.anchor !== undefined) { throw new Error('icon_set_target'); }
  const field = group.get('icon', true);
  if (isScalar(field) && field.anchor !== undefined) { throw new Error('icon_set_target'); }
  if (field !== undefined && !isScalar(field) && !isAlias(field)) { throw new Error('icon_set_target'); }
  if (source === target.icon) { return text; }
  return writeProfileYamlField(text, document, group, 'icon', source);
}

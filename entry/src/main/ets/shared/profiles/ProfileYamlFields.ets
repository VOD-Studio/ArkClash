import { Document, isMap, isSeq, parseDocument, Scalar, SchemaOptions, ToStringOptions, YAMLMap, YAMLSeq } from 'yaml';

export type ProfileYamlMapping = YAMLMap<Object, Object>;
export type ProfileYamlSequence = YAMLSeq<Object>;

export interface ProfileYamlGroup {
  name: string;
  index: number;
}

export function readProfileYaml(text: string, invalid: string): Document<ProfileYamlMapping> {
  const options: SchemaOptions = { merge: true };
  const document = parseDocument(text, options);
  if (document.errors.length > 0 || !isMap(document.contents)) { throw new Error(invalid); }
  return document as Document<ProfileYamlMapping>;
}

export function profileYamlGroups(root: ProfileYamlMapping): ProfileYamlGroup[] {
  const groups = root.get('proxy-groups');
  const result: ProfileYamlGroup[] = [];
  if (isSeq(groups)) {
    const items = (groups as ProfileYamlSequence).items;
    for (let index = 0; index < items.length; index++) {
      const group = items[index];
      if (!isMap(group)) { continue; }
      const name = (group as ProfileYamlMapping).get('name');
      if (typeof name === 'string' && name !== '') { result.push({ name: name, index: index }); }
    }
  }
  return result;
}

export function profileYamlGroup(root: ProfileYamlMapping, target: ProfileYamlGroup): ProfileYamlMapping | undefined {
  const groups = root.get('proxy-groups');
  if (!isSeq(groups)) { return undefined; }
  const group = (groups as ProfileYamlSequence).items[target.index];
  if (isMap(group) && (group as ProfileYamlMapping).get('name') === target.name) { return group as ProfileYamlMapping; }
  return undefined;
}

export function writeProfileYamlField(text: string, document: Document<ProfileYamlMapping>, destination: ProfileYamlMapping,
  field: string, value: string): string {
  const quoted = JSON.stringify(value);
  const node = destination.get(field, true);
  const range = node?.range ?? undefined;
  if (range !== undefined && range[0] < range[1] && node?.tag === undefined &&
    node?.type !== Scalar.BLOCK_FOLDED && node?.type !== Scalar.BLOCK_LITERAL) {
    return text.slice(0, range[0]) + quoted + text.slice(range[1]);
  }
  const mappingRange = destination.range ?? undefined;
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  if (node === undefined && mappingRange !== undefined) {
    if (destination.flow && text[mappingRange[0]] === '{') {
      const offset = mappingRange[0] + 1;
      const delimiter = destination.items.length === 0 ? '' : ', ';
      return text.slice(0, offset) + field + ': ' + quoted + delimiter + text.slice(offset);
    }
    const start = mappingRange[0];
    const lineStart = text.lastIndexOf('\n', start - 1) + 1;
    const prefix = text.slice(lineStart, start);
    if (!destination.flow && /^ *(?:- +)?$/.test(prefix)) {
      const end = mappingRange[1];
      const line = ' '.repeat(prefix.length) + field + ': ' + quoted;
      return text[end - 1] === '\n' ? text.slice(0, end) + line + newline + text.slice(end) :
        text.slice(0, end) + newline + line + (end === text.length ? '' : newline) + text.slice(end);
    }
  }
  destination.set(field, value);
  const options: ToStringOptions = { lineWidth: 0 };
  const updated = document.toString(options);
  return newline === '\r\n' ? updated.replace(/\n/g, '\r\n') : updated;
}

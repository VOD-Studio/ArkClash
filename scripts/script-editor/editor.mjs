import { autocompletion, completionKeymap, startCompletion } from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { javascript, javascriptLanguage } from '@codemirror/lang-javascript';
import { bracketMatching, indentOnInput, indentUnit, HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { closeSearchPanel, openSearchPanel, search, searchKeymap, searchPanelOpen } from '@codemirror/search';
import { Compartment, EditorState } from '@codemirror/state';
import { crosshairCursor, drawSelection, EditorView, highlightActiveLine, highlightActiveLineGutter,
  highlightSpecialChars, keymap, lineNumbers } from '@codemirror/view';
import { tags } from '@lezer/highlight';

const phrases = {
  Find: '查找', Replace: '替换', next: '下一个', previous: '上一个', all: '全部',
  'match case': '区分大小写', regexp: '正则', 'by word': '全词', replace: '替换',
  'replace all': '全部替换', 'close search': '关闭查找', 'Go to line': '转到行',
};
const fields = ['proxies', 'proxy-groups', 'proxy-providers', 'rule-providers', 'rules', 'sub-rules',
  'dns', 'mode', 'hosts', 'sniffer', 'ntp', 'ipv6', 'mixed-port', 'port', 'socks-port', 'allow-lan',
  'geox-url', 'listeners', 'tunnels', 'log-level', 'unified-delay', 'tcp-concurrent'];
const variables = ['config', 'main', 'console', 'Array', 'Object', 'String', 'Number', 'Map', 'Set', 'Promise',
  'RegExp', 'Math', 'JSON', 'Date', 'Reflect', 'BigInt', 'undefined'];
const consoleMethods = ['log', 'info', 'warn', 'error', 'debug', 'trace'];

function completeConfig(context) {
  const property = context.matchBefore(/\bconfig\[(['"])[\w-]*$/);
  if (property) {
    const from = property.from + 'config['.length + 1;
    return { from, options: fields.map(label => ({ label, type: 'property' })), validFor: /^[\w-]*$/ };
  }
  const consoleProperty = context.matchBefore(/\bconsole\.\w*$/);
  if (consoleProperty) {
    return { from: consoleProperty.from + 'console.'.length, options: consoleMethods.map(label => ({ label, type: 'method' })) };
  }
  const word = context.matchBefore(/\w*/);
  if (!word || (!word.text && !context.explicit)) return null;
  return { from: word.from, options: variables.map(label => ({ label, type: 'variable' })), validFor: /^\w*$/ };
}

function theme(dark) {
  return [EditorView.theme({}, { dark }), syntaxHighlighting(HighlightStyle.define([
    { tag: tags.comment, color: dark ? '#9baca2' : '#456a51', fontStyle: 'italic' },
    { tag: [tags.keyword, tags.operatorKeyword], color: dark ? '#e8a9ff' : '#79239e' },
    { tag: [tags.string, tags.regexp], color: dark ? '#a5d994' : '#39722c' },
    { tag: [tags.number, tags.bool, tags.null], color: dark ? '#ffc78f' : '#9e4d06' },
    { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: dark ? '#91c7ff' : '#165ca1' },
    { tag: [tags.propertyName, tags.definition(tags.variableName)], color: dark ? '#ffbbac' : '#8a371e' },
  ]))];
}

let editor;
let original;
let reported;
const wrapping = new Compartment();
const appearance = new Compartment();

function report(update) {
  const { state } = update;
  const canUndo = undoDepth(state) > 0;
  const canRedo = redoDepth(state) > 0;
  if (!update.docChanged && reported) return;
  const dirty = !state.doc.eq(original);
  const signature = `${dirty}:${canUndo}:${canRedo}`;
  if (signature !== reported) window.ArkEditorStatus?.changed(dirty, canUndo, canRedo);
  reported = signature;
}

function setAppearance(settings) {
  const root = document.documentElement;
  root.classList.toggle('dark', settings.dark);
  root.style.setProperty('--surface', settings.surface);
  root.style.setProperty('--accent', settings.accent);
  root.style.setProperty('--font', `${settings.font}px`);
  editor.dispatch({ effects: [appearance.reconfigure(theme(settings.dark)),
    wrapping.reconfigure(settings.wrap ? EditorView.lineWrapping : [])] });
}

window.arkScriptEditor = {
  open(source, settings) {
    editor?.destroy();
    reported = '';
    editor = new EditorView({ parent: document.querySelector('#editor'), state: EditorState.create({ doc: source,
      extensions: [lineNumbers(), highlightActiveLine(), highlightActiveLineGutter(), highlightSpecialChars(),
        history(), drawSelection(), crosshairCursor(), indentOnInput(), indentUnit.of('  '), bracketMatching(),
        javascript(), javascriptLanguage.data.of({ autocomplete: completeConfig }), autocompletion(),
        search({ top: true }), EditorState.phrases.of(settings.chinese ? phrases : {}),
        EditorView.contentAttributes.of({ 'aria-label': settings.chinese ? 'JavaScript 编辑器' : 'JavaScript editor',
          autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' }),
        keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, ...completionKeymap]),
        EditorView.updateListener.of(report), wrapping.of([]), appearance.of(theme(false))],
    }) });
    original = editor.state.doc;
    setAppearance(settings);
    return true;
  },
  appearance: setAppearance,
  source() { return editor.state.doc.toString(); },
  selection() { const { from, to } = editor.state.selection.main; return editor.state.sliceDoc(from, to); },
  undo() { undo(editor); editor.focus(); },
  redo() { redo(editor); editor.focus(); },
  complete() { startCompletion(editor); editor.focus(); },
  search() { if (searchPanelOpen(editor.state)) closeSearchPanel(editor); else openSearchPanel(editor); },
  selectAll() { editor.dispatch({ selection: { anchor: 0, head: editor.state.doc.length } }); editor.focus(); },
};

import { autocompletion, completionKeymap, startCompletion } from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { javascript, javascriptLanguage } from '@codemirror/lang-javascript';
import { bracketMatching, indentOnInput, indentUnit, HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { closeSearchPanel, openSearchPanel, search, searchKeymap, searchPanelOpen } from '@codemirror/search';
import { Compartment, EditorState } from '@codemirror/state';
import { crosshairCursor, drawSelection, EditorView, highlightActiveLine, highlightActiveLineGutter,
  highlightSpecialChars, keymap, lineNumbers } from '@codemirror/view';
import { tags } from '@lezer/highlight';
import { completeMihomoYaml, yamlLanguage } from './yaml.mjs';

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
    { tag: [tags.keyword, tags.operatorKeyword, tags.meta], color: dark ? '#e8a9ff' : '#79239e' },
    { tag: [tags.string, tags.regexp], color: dark ? '#a5d994' : '#39722c' },
    { tag: [tags.number, tags.bool, tags.null, tags.atom], color: dark ? '#ffc78f' : '#9e4d06' },
    { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: dark ? '#91c7ff' : '#165ca1' },
    { tag: [tags.propertyName, tags.definition(tags.variableName)], color: dark ? '#ffbbac' : '#8a371e' },
  ]))];
}

let editor;
let original;
let reported;
let readOnlyMode = false;
let topInset = 0;
let pendingOpenSettings = null;
let pendingOpenChunks = [];
let pendingReplaceChunks = [];
const wrapping = new Compartment();
const appearance = new Compartment();

function reserveSearchPanel(height) {
  document.documentElement.style.setProperty('--search-height', `${height}px`);
  editor?.requestMeasure();
}

const searchPanelSize = new ResizeObserver(([entry]) => {
  if (entry.target.isConnected) reserveSearchPanel(entry.borderBoxSize[0].blockSize);
});

function trackSearchPanel(update) {
  const open = searchPanelOpen(update.state);
  if (open === searchPanelOpen(update.startState)) return;
  searchPanelSize.disconnect();
  const panel = open && update.view.dom.querySelector('.cm-panels-top');
  if (panel) searchPanelSize.observe(panel);
  else reserveSearchPanel(0);
}

function report(update) {
  const { state } = update;
  const canUndo = !readOnlyMode && undoDepth(state) > 0;
  const canRedo = !readOnlyMode && redoDepth(state) > 0;
  if (!update.docChanged && reported) return;
  const dirty = !readOnlyMode && !state.doc.eq(original);
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

function languageExtensions(language, readOnly) {
  if (language === 'yaml') {
    const base = [yamlLanguage];
    if (!readOnly) base.push(autocompletion({ override: [completeMihomoYaml] }));
    return base;
  }
  const base = [javascript()];
  if (!readOnly) {
    base.push(javascriptLanguage.data.of({ autocomplete: completeConfig }), autocompletion());
  }
  return base;
}

function ariaLabel(settings) {
  const isYaml = settings.language === 'yaml';
  if (settings.chinese) {
    if (isYaml) return settings.readOnly ? '运行时 YAML 配置预览' : 'YAML 编辑器';
    return 'JavaScript 编辑器';
  }
  if (isYaml) return settings.readOnly ? 'Runtime YAML preview' : 'YAML editor';
  return 'JavaScript editor';
}

function openDocument(source, settings) {
  searchPanelSize.disconnect();
  document.documentElement.style.removeProperty('--search-height');
  editor?.destroy();
  reported = '';
  readOnlyMode = Boolean(settings.readOnly);
  const language = settings.language === 'yaml' ? 'yaml' : 'javascript';
  const extensions = [
    lineNumbers(), highlightActiveLine(), highlightActiveLineGutter(), highlightSpecialChars(),
    indentUnit.of('  '), bracketMatching(),
    ...languageExtensions(language, readOnlyMode),
    search({ top: true }), EditorState.phrases.of(settings.chinese ? phrases : {}),
    EditorView.updateListener.of(trackSearchPanel),
    EditorView.scrollMargins.of(() => ({ top: topInset })),
    EditorView.contentAttributes.of({ 'aria-label': ariaLabel(settings),
      autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' }),
    wrapping.of([]), appearance.of(theme(false)),
  ];
  if (readOnlyMode) {
    extensions.push(
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      keymap.of([...searchKeymap]),
    );
  } else {
    extensions.push(
      history(), drawSelection(), crosshairCursor(), indentOnInput(),
      keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, ...completionKeymap]),
      EditorView.updateListener.of(report),
    );
  }
  editor = new EditorView({
    parent: document.querySelector('#editor'),
    state: EditorState.create({ doc: source, extensions }),
  });
  original = editor.state.doc;
  setAppearance(settings);
  return true;
}

function replaceDocumentText(text) {
  if (!editor || readOnlyMode) return false;
  editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: text } });
  return true;
}

window.arkScriptEditor = {
  setTopInset(inset) {
    topInset = Math.max(0, inset);
    document.documentElement.style.setProperty('--editor-top', `${topInset}px`);
    editor?.requestMeasure();
  },
  open(source, settings) {
    return openDocument(source, settings);
  },
  // 大配置通过分片写入和分片读回，避免单次 runJavaScript 参数或返回值过大。
  beginOpen(settings) {
    pendingOpenSettings = settings;
    pendingOpenChunks = [];
    return true;
  },
  appendChunk(chunk) {
    pendingOpenChunks.push(chunk);
    return true;
  },
  finishOpen() {
    const source = pendingOpenChunks.join('');
    const settings = pendingOpenSettings ?? {};
    pendingOpenChunks = [];
    pendingOpenSettings = null;
    return openDocument(source, settings);
  },
  beginReplace() {
    pendingReplaceChunks = [];
    return true;
  },
  appendReplaceChunk(chunk) {
    pendingReplaceChunks.push(chunk);
    return true;
  },
  finishReplace() {
    const text = pendingReplaceChunks.join('');
    pendingReplaceChunks = [];
    return replaceDocumentText(text);
  },
  replaceDocument: replaceDocumentText,
  appearance: setAppearance,
  length() { return editor ? editor.state.doc.length : 0; },
  slice(from, to) { return editor ? editor.state.doc.sliceString(from, to) : ''; },
  source() { return editor.state.doc.toString(); },
  selection() { const { from, to } = editor.state.selection.main; return editor.state.sliceDoc(from, to); },
  undo() { if (!readOnlyMode) { undo(editor); editor.focus(); } },
  redo() { if (!readOnlyMode) { redo(editor); editor.focus(); } },
  complete() { if (!readOnlyMode) { startCompletion(editor); editor.focus(); } },
  search() { if (searchPanelOpen(editor.state)) closeSearchPanel(editor); else openSearchPanel(editor); },
  selectAll() { editor.dispatch({ selection: { anchor: 0, head: editor.state.doc.length } }); editor.focus(); },
};

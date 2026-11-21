import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DiagnosticConnection, DiagnosticDnsRecord } from '../../client/Diagnostics';
import { AppGlyph } from '../../components/AppGlyph';
import { formatBytes } from '../../components/Format';
import { uiResourceText } from '../../components/ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { connectionRule, ConnectionRecordView, diagnosticEndpoint } from './RecordLogic';
import { recordColumnTitle, recordFacetText, recordInitiatorText } from './RecordLabels';

interface RecordDetailField {
  key: string;
  title: ResourceStr;
  text: ResourceStr;
  copyText: string;
}

function appendRecordDetail(fields: RecordDetailField[], key: string, text: string): void {
  if (text !== '') {
    fields.push({ key: key, title: recordColumnTitle(key), text: text, copyText: text });
  }
}

function connectionCreationTime(start: string): string {
  const date = new Date(start);
  if (!Number.isFinite(date.getTime())) { return start; }
  const month = `${date.getMonth() + 1}`.padStart(2, '0');
  const day = `${date.getDate()}`.padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day} ${date.toTimeString().slice(0, 8)}`;
}

function connectionBasicFields(record: DiagnosticConnection): RecordDetailField[] {
  const fields: RecordDetailField[] = [];
  const start = connectionCreationTime(record.start);
  fields.push({ key: 'creationTime', title: $r('app.string.diagnostics_creation_time'), text: start, copyText: start });
  if (record.metadata.network !== '') {
    fields.push({ key: 'network', title: $r('app.string.diagnostics_network_type'),
      text: record.metadata.network, copyText: record.metadata.network });
  }
  appendRecordDetail(fields, 'rule', connectionRule(record));
  appendRecordDetail(fields, 'upload', formatBytes(record.upload));
  appendRecordDetail(fields, 'download', formatBytes(record.download));
  return fields;
}

function connectionAddressFields(record: DiagnosticConnection): RecordDetailField[] {
  const fields: RecordDetailField[] = [];
  const metadata = record.metadata;
  appendRecordDetail(fields, 'host', metadata.host);
  appendRecordDetail(fields, 'source', diagnosticEndpoint(metadata.sourceIP, metadata.sourcePort));
  appendRecordDetail(fields, 'destination', diagnosticEndpoint(metadata.destinationIP, metadata.destinationPort));
  appendRecordDetail(fields, 'destinationGeoIP', metadata.destinationGeoIP.join(' '));
  appendRecordDetail(fields, 'destinationIPASN', metadata.destinationIPASN);
  appendRecordDetail(fields, 'remoteDestination', metadata.remoteDestination);
  return fields;
}

function connectionProxyFields(record: DiagnosticConnection): RecordDetailField[] {
  const fields: RecordDetailField[] = [];
  appendRecordDetail(fields, 'specialProxy', record.metadata.specialProxy);
  appendRecordDetail(fields, 'specialRules', record.metadata.specialRules);
  appendRecordDetail(fields, 'dnsMode', record.metadata.dnsMode);
  return fields;
}

@Extend(Text)
function connectionDetailLabel() {
  .fontSize(17)
  .lineHeight(22)
  .fontColor($r('sys.color.font_primary'))
  .constraintSize({ maxWidth: '45%' })
}

@Extend(Row)
function connectionDetailRow() {
  .width('100%')
  .constraintSize({ minHeight: 56 })
  .alignItems(VerticalAlign.Center)
  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
}

@ComponentV2
struct ConnectionDetailSection {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param titleText: ResourceStr = '';
  @Param fields: RecordDetailField[] = [];
  @Param chains: string[] | undefined = undefined;
  @Event onCopy: (text: string) => void = () => {};

  build() {
    Column() {
      Text(this.titleText)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(17)
        .lineHeight(22)
        .fontWeight(600)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .constraintSize({ minHeight: 32 })
        .padding({ left: 16, right: 16 })
        .margin({ top: 19, bottom: 6 })
      Column() {
        ForEach(this.fields, (field: RecordDetailField, index: number) => {
          if (index > 0) {
            Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
          }
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Row({ space: 20 }) {
              Text(field.title).fontFamily(this.appStyle.fontFamily).connectionDetailLabel()
              Text(field.text)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(15)
                .lineHeight(20)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.End)
                .wordBreak(WordBreak.BREAK_WORD)
                .layoutWeight(1)
            }
            .connectionDetailRow()
          }
          .width('100%')
          .padding(0)
          .onClick((): void => { this.onCopy(field.copyText); })
        }, (field: RecordDetailField): string => field.key)
        if (this.chains !== undefined) {
          if (this.fields.length > 0) {
            Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
          }
          Row({ space: 20 }) {
            Text($r('app.string.diagnostics_chains')).fontFamily(this.appStyle.fontFamily).connectionDetailLabel()
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End, alignItems: ItemAlign.Center }) {
              ForEach(this.chains, (hop: string, index: number) => {
                Row({ space: 6 }) {
                  if (index > 0) {
                    Text('→').fontFamily(this.appStyle.fontFamily).fontSize(12).fontColor($r('sys.color.font_secondary'))
                  }
                  Text(hop)
                    .fontFamily(this.appStyle.fontFamily)
                    .fontSize(11)
                    .lineHeight(13)
                    .fontWeight(600)
                    .fontColor($r('sys.color.font_secondary'))
                    .wordBreak(WordBreak.BREAK_WORD)
                    .flexShrink(1)
                    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                    .borderRadius(8)
                    .backgroundColor(this.appStyle.palette.surfaceBlock)
                }
                .constraintSize({ maxWidth: '100%' })
                .margin({ left: 6, top: 2, bottom: 2 })
              }, (hop: string, index: number): string => `${index}:${hop}`)
            }
            .layoutWeight(1)
          }
          .connectionDetailRow()
        }
      }
      .width('100%')
      .backgroundColor(this.appStyle.palette.cardBackground)
      .borderRadius(24)
      .clip(true)
    }
    .width('100%')
  }
}

function dnsDetailFields(record: DiagnosticDnsRecord): RecordDetailField[] {
  const fields: RecordDetailField[] = [];
  appendRecordDetail(fields, 'time', record.time);
  appendRecordDetail(fields, 'domain', record.domain);
  appendRecordDetail(fields, 'type', record.type);
  fields.push({ key: 'initiator', title: recordColumnTitle('initiator'),
    text: recordInitiatorText(record.initiator), copyText: record.initiator });
  fields.push({ key: 'cache', title: recordColumnTitle('cache'),
    text: recordFacetText('cache', record.cached ? 'true' : 'false'), copyText: record.cached ? 'true' : 'false' });
  appendRecordDetail(fields, 'rcode', record.rcode);
  appendRecordDetail(fields, 'error', record.error);
  appendRecordDetail(fields, 'answers', record.answers.join('\n'));
  fields.push({ key: 'upstream', title: recordColumnTitle('upstream'),
    text: record.upstream === '' ? '—' : record.upstream, copyText: record.upstream });
  appendRecordDetail(fields, 'elapsed', `${record.delay} ms`);
  return fields;
}

@ComponentV2
struct RecordDetailValues {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param fields: RecordDetailField[] = [];
  @Param interruptions: number = 0;
  @Param dropped: number = 0;
  @Param evicted: number = 0;
  @Event onCopy: (text: string) => void = () => {};

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text($r('app.string.diagnostics_details'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(COMPACT_TITLE_SIZE).lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
        Column() {
          ForEach(this.fields, (field: RecordDetailField) => {
            Row({ space: 12 }) {
              Column({ space: 6 }) {
                Text(field.title).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
                Text(field.text).fontFamily(this.appStyle.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
                  .wordBreak(WordBreak.BREAK_ALL)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              if (field.copyText !== '') {
                Button({ type: ButtonType.Circle }) {
                  AppGlyph({ name: 'copy', iconSize: 18 })
                }
                .width(40).height(40).buttonStyle(ButtonStyleMode.NORMAL)
                .accessibilityText($r('app.string.diagnostics_copy_value'))
                .accessibilityDescription(uiResourceText(this.getUIContext(), field.title))
                .onClick((): void => { this.onCopy(field.copyText); })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding(16)
          }, (field: RecordDetailField): string => field.key)
        }
        .width('100%').borderRadius(22).backgroundColor(this.appStyle.palette.cardBackground)
        Text($r('app.string.diagnostics_collect_hint')).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        if (this.interruptions > 0 || this.dropped > 0 || this.evicted > 0) {
          Text($r('app.string.diagnostics_gap', this.interruptions, this.dropped, this.evicted))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 32 })
    }
    .width('100%').height('100%')
  }
}

@ComponentV2
export struct ConnectionRecordDetails {
  @Param @Once record: ConnectionRecordView | undefined = undefined;
  @Event onCopy: (text: string) => void = () => {};

  @Computed
  get basicFields(): RecordDetailField[] {
    return this.record === undefined ? [] : connectionBasicFields(this.record.connection);
  }

  @Computed
  get addressFields(): RecordDetailField[] {
    return this.record === undefined ? [] : connectionAddressFields(this.record.connection);
  }

  @Computed
  get proxyFields(): RecordDetailField[] {
    return this.record === undefined ? [] : connectionProxyFields(this.record.connection);
  }

  @Computed
  get chains(): string[] {
    return this.record?.connection.chains.slice().reverse() ?? [];
  }

  build() {
    Scroll() {
      Column() {
        if (this.record !== undefined) {
          ConnectionDetailSection({ titleText: $r('app.string.diagnostics_basic_info'), fields: this.basicFields,
            onCopy: (text: string): void => { this.onCopy(text); } })
          if (this.addressFields.length > 0) {
            ConnectionDetailSection({ titleText: $r('app.string.diagnostics_address'), fields: this.addressFields,
              onCopy: (text: string): void => { this.onCopy(text); } })
          }
          ConnectionDetailSection({ titleText: $r('app.string.tab_proxies'), fields: this.proxyFields,
            chains: this.chains, onCopy: (text: string): void => { this.onCopy(text); } })
        }
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
  }
}

@ComponentV2
export struct DnsRecordDetails {
  @Param record: DiagnosticDnsRecord | undefined = undefined;
  @Param interruptions: number = 0;
  @Param dropped: number = 0;
  @Param evicted: number = 0;
  @Event onCopy: (text: string) => void = () => {};

  @Computed
  get fields(): RecordDetailField[] {
    return this.record === undefined ? [] : dnsDetailFields(this.record);
  }

  build() {
    RecordDetailValues({ fields: this.fields, interruptions: this.interruptions,
      dropped: this.dropped, evicted: this.evicted, onCopy: (text: string): void => { this.onCopy(text); } })
  }
}

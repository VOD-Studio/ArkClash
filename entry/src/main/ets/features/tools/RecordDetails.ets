import { DiagnosticConnection, DiagnosticDnsRecord } from '../../client/Diagnostics';
import { AppGlyph } from '../../components/AppGlyph';
import { formatBytes } from '../../components/Format';
import { uiResourceText } from '../../components/ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { ConnectionRecordView, diagnosticEndpoint } from './RecordLogic';
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

function connectionDetailFields(view: ConnectionRecordView): RecordDetailField[] {
  const record: DiagnosticConnection = view.connection;
  const fields: RecordDetailField[] = [];
  appendRecordDetail(fields, 'time', record.start);
  appendRecordDetail(fields, 'host', record.metadata.host);
  appendRecordDetail(fields, 'network', record.metadata.network);
  appendRecordDetail(fields, 'type', record.metadata.type);
  appendRecordDetail(fields, 'source', diagnosticEndpoint(record.metadata.sourceIP, record.metadata.sourcePort));
  appendRecordDetail(fields, 'destination', diagnosticEndpoint(
    record.metadata.destinationIP === '' ? record.metadata.host : record.metadata.destinationIP,
    record.metadata.destinationPort));
  appendRecordDetail(fields, 'rule', record.rule);
  appendRecordDetail(fields, 'rulePayload', record.rulePayload);
  appendRecordDetail(fields, 'download', formatBytes(record.download));
  appendRecordDetail(fields, 'upload', formatBytes(record.upload));
  if (view.duration > 0) { appendRecordDetail(fields, 'duration', `${Math.floor(view.duration / 1000)} s`); }
  appendRecordDetail(fields, 'sourceGeoIP', record.metadata.sourceGeoIP.join(', '));
  appendRecordDetail(fields, 'destinationGeoIP', record.metadata.destinationGeoIP.join(', '));
  appendRecordDetail(fields, 'sourceIPASN', record.metadata.sourceIPASN);
  appendRecordDetail(fields, 'destinationIPASN', record.metadata.destinationIPASN);
  appendRecordDetail(fields, 'dnsMode', record.metadata.dnsMode);
  appendRecordDetail(fields, 'remoteDestination', record.metadata.remoteDestination);
  appendRecordDetail(fields, 'specialProxy', record.metadata.specialProxy);
  appendRecordDetail(fields, 'specialRules', record.metadata.specialRules);
  appendRecordDetail(fields, 'sniffHost', record.metadata.sniffHost);
  appendRecordDetail(fields, 'chains', record.chains.slice().reverse().join(' → '));
  appendRecordDetail(fields, 'providerChains', record.providerChains.slice().reverse().join(' → '));
  return fields;
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
  @Param fields: RecordDetailField[] = [];
  @Param interruptions: number = 0;
  @Param dropped: number = 0;
  @Param evicted: number = 0;
  @Event onCopy: (text: string) => void = () => {};

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text($r('app.string.diagnostics_details'))
          .fontSize(COMPACT_TITLE_SIZE).lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
        Column() {
          ForEach(this.fields, (field: RecordDetailField) => {
            Row({ space: 12 }) {
              Column({ space: 6 }) {
                Text(field.title).fontSize(13).fontColor($r('sys.color.font_secondary'))
                Text(field.text).fontSize(16).fontColor($r('sys.color.font_primary'))
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
        .width('100%').borderRadius(22).backgroundColor($r('app.color.card_background'))
        Text($r('app.string.diagnostics_collect_hint')).fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        if (this.interruptions > 0 || this.dropped > 0 || this.evicted > 0) {
          Text($r('app.string.diagnostics_gap', this.interruptions, this.dropped, this.evicted))
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
  @Param record: ConnectionRecordView | undefined = undefined;
  @Param interruptions: number = 0;
  @Param dropped: number = 0;
  @Param evicted: number = 0;
  @Event onCopy: (text: string) => void = () => {};

  @Computed
  get fields(): RecordDetailField[] {
    return this.record === undefined ? [] : connectionDetailFields(this.record);
  }

  build() {
    RecordDetailValues({ fields: this.fields, interruptions: this.interruptions,
      dropped: this.dropped, evicted: this.evicted, onCopy: (text: string): void => { this.onCopy(text); } })
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

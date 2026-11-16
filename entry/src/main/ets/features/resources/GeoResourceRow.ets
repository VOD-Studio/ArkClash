import { formatBytes, formatUpdatedAgo } from '../../components/Format';
import { uiResourceText } from '../../components/ResourceText';
import { GeoResourceItem } from './Resources';
import { geoErrorText } from './GeoResourceEditor';

@ComponentV2
export struct GeoResourceRow {
  @Param @Require item: GeoResourceItem;
  @Param now: number = 0;
  @Param canSync: boolean = false;
  @Event onEdit: () => void = () => {};
  @Event onActions: () => void = () => {};

  build() {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text(this.item.id.toUpperCase())
          .fontSize(17)
          .fontColor($r('sys.color.font_primary'))
        Text(this.item.exists ? formatUpdatedAgo(this.item.modifiedAt, this.now) : $r('app.string.geo_not_downloaded'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .accessibilityDescription(uiResourceText(this.getUIContext(),
            this.item.exists ? new Date(this.item.modifiedAt).toLocaleString() : $r('app.string.geo_not_downloaded')))
        if (this.item.error !== '') {
          Text(geoErrorText(this.item.error))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.item.phase === 'queued' || this.item.phase === 'updating') {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('sys.color.font_secondary'))
          .accessibilityText(this.item.phase === 'queued' ? $r('app.string.geo_queued') :
            $r('app.string.geo_updating'))
      } else if (this.item.exists) {
        Text(formatBytes(this.item.size))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .fontFeature('"tnum" on')
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .accessibilityDescription(this.canSync ? $r('app.string.geo_row_actions') :
      $r('app.string.geo_connect_to_update'))
    .gesture(GestureGroup(GestureMode.Exclusive,
      LongPressGesture({ repeat: false }).onAction((): void => { this.onActions(); }),
      TapGesture().onAction((): void => { this.onEdit(); })
    ))
  }
}

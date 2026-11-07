// 卡片里的小标签和「标题 + 数值」。做成组件而不是 @Builder：@Builder 按值传参，状态变了不会刷新。

/** 胶囊标签，可带一个状态圆点。空间不够时文字缩短并显示省略号。 */
@ComponentV2
export struct Tag {
  @Param text: ResourceStr = '';
  @Param color: ResourceColor = $r('sys.color.font_secondary');
  @Param tint: ResourceColor = $r('app.color.tile_background'); // 底色
  @Param dot: boolean = false;

  build() {
    Row({ space: 4 }) {
      if (this.dot) {
        Circle()
          .width(6)
          .height(6)
          .fill(this.color)
      }
      Text(this.text)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
    }
    .height(22)
    .padding({ left: 8, right: 8 })
    .borderRadius(11)
    .backgroundColor(this.tint)
  }
}

/** 上面一行小字说明，下面一行数值。等分一行时配合 layoutWeight 使用。 */
@ComponentV2
export struct LabeledValue {
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';

  build() {
    Column({ space: 2 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
      Text(this.value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .fontFeature('"tnum" on')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
  }
}

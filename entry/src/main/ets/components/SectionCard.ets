@Component
export struct SectionCard {
  @Prop title: string = '';
  @Builder slot() {}

  build() {
    Column() {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
          .margin({ bottom: 8 })
      }
      this.slot()
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .padding(16)
  }
}

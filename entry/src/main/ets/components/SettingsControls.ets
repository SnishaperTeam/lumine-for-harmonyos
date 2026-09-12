@Component
export struct SwitchRow {
  @Prop label: string = '';
  @Prop checked: boolean = false;
  onToggle?: (val: boolean) => void;

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .onChange((isOn: boolean) => {
          if (this.onToggle) {
            this.onToggle(isOn);
          }
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
  }
}

@Component
export struct InputRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop placeholder: string = '';
  onInput?: (val: string) => void;

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
        .width(100)
      TextInput({ text: this.value, placeholder: this.placeholder })
        .layoutWeight(1)
        .fontSize(14)
        .onChange((val: string) => {
          if (this.onInput) {
            this.onInput(val);
          }
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
  }
}

@Component
export struct SelectorRow {
  @Prop label: string = '';
  @Prop options: string[] = [];
  @Prop selectedIndex: number = 0;
  onSelect?: (index: number) => void;

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
        .width(100)
      Select(this.options.map((opt: string) => ({ value: opt } as SelectOption)))
        .selected(this.selectedIndex)
        .value(this.options[this.selectedIndex] ?? '')
        .layoutWeight(1)
        .fontSize(14)
        .onSelect((_index: number) => {
          if (this.onSelect) {
            this.onSelect(_index);
          }
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
  }
}

@Component
export struct StatsPanel {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column() {
      Text(this.value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
      Text(this.label)
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .height(60)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .padding(8)
  }
}

@Component
export struct SectionTitle {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(14)
      .fontColor($r('app.color.font_secondary'))
      .width('100%')
      .margin({ top: 16, bottom: 8 })
      .padding({ left: 16 })
  }
}

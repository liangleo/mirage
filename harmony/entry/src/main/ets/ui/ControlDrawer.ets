@Component
export struct ControlDrawer {
  @Prop inputOn: boolean;
  @Prop keyboardOn: boolean;
  @Prop capsOk: boolean;
  @Prop gateEnabled: boolean;
  @Prop gateReason: string;
  onToggleInput: () => void = () => {
  };
  onToggleKeyboard: () => void = () => {
  };
  onDisconnect: () => void = () => {
  };
  onClose: () => void = () => {
  };

  build() {
    Column({ space: 16 }) {
      Row() {
        Text('输入').fontSize(16).fontColor(Color.White)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.inputOn })
          .enabled(this.capsOk)
          .onChange((isOn: boolean) => {
            if (isOn !== this.inputOn) {
              this.onToggleInput();
            }
          })
      }
      .width('100%')

      if (!this.capsOk) {
        Text('服务端未开放输入').fontSize(12).fontColor('#999999')
      } else if (!this.gateEnabled) {
        Text(this.gateReason.length > 0 ? this.gateReason : '输入已暂停')
          .fontSize(12)
          .fontColor('#FFB020')
      }

      Row() {
        Text('键盘').fontSize(16).fontColor(Color.White)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.keyboardOn })
          .enabled(this.capsOk)
          .onChange((isOn: boolean) => {
            if (isOn !== this.keyboardOn) {
              this.onToggleKeyboard();
            }
          })
      }
      .width('100%')

      Blank()

      Button('断开连接')
        .width('100%')
        .fontColor('#FF5A5A')
        .backgroundColor('#222222')
        .onClick(() => {
          this.onDisconnect();
        })

      Button('关闭')
        .width('100%')
        .backgroundColor('#333333')
        .onClick(() => {
          this.onClose();
        })
    }
    .width(260)
    .height('100%')
    .padding(16)
    .backgroundColor('#CC000000')
  }
}
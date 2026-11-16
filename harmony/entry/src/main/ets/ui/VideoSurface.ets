@Component
export struct VideoSurface {
  @Prop configWidth: number;
  @Prop configHeight: number;
  onSurfaceReady: (surfaceId: string) => void = (surfaceId: string) => {
  };
  onSurfaceDestroyed: () => void = () => {
  };
  @State private renderWidth: number = 0;
  @State private renderHeight: number = 0;
  private controller: XComponentController = new XComponentController();

  private fit(containerWidth: number, containerHeight: number): void {
    if (containerWidth <= 0 || containerHeight <= 0) {
      return;
    }
    const width = this.configWidth > 0 ? this.configWidth : 16;
    const height = this.configHeight > 0 ? this.configHeight : 9;
    const scale = Math.min(containerWidth / width, containerHeight / height);
    this.renderWidth = Math.floor(width * scale);
    this.renderHeight = Math.floor(height * scale);
  }

  build() {
    Column() {
      XComponent({ type: XComponentType.SURFACE, controller: this.controller })
        .width(this.renderWidth > 0 ? this.renderWidth : '100%')
        .height(this.renderHeight > 0 ? this.renderHeight : '100%')
        .backgroundColor(Color.Black)
        .onLoad(() => {
          this.onSurfaceReady(this.controller.getXComponentSurfaceId());
        })
        .onDestroy(() => {
          this.onSurfaceDestroyed();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.Black)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.fit(Number(newValue.width), Number(newValue.height));
    })
  }
}
import { ContentRect, fitContent } from '../input/InputGeometry';

@Component
export struct VideoSurface {
  @Prop @Watch('refit') configWidth: number;
  @Prop @Watch('refit') configHeight: number;
  onSurfaceReady: (surfaceId: string) => void = (surfaceId: string) => {
  };
  onSurfaceDestroyed: () => void = () => {
  };
  onContentRect: (rect: ContentRect) => void = (rect: ContentRect) => {
  };
  @State private renderWidth: number = 0;
  @State private renderHeight: number = 0;
  private containerWidth: number = 0;
  private containerHeight: number = 0;
  private controller: XComponentController = new XComponentController();

  private refit(): void {
    this.fit(this.containerWidth, this.containerHeight);
  }

  private fit(containerWidth: number, containerHeight: number): void {
    if (containerWidth <= 0 || containerHeight <= 0) {
      return;
    }
    const rect: ContentRect = fitContent(containerWidth, containerHeight,
      this.configWidth > 0 ? this.configWidth : 16, this.configHeight > 0 ? this.configHeight : 9);
    if (rect.width !== this.renderWidth || rect.height !== this.renderHeight) {
      this.renderWidth = rect.width;
      this.renderHeight = rect.height;
      this.onContentRect(rect);
    }
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
      this.containerWidth = Number(newValue.width);
      this.containerHeight = Number(newValue.height);
      this.fit(this.containerWidth, this.containerHeight);
    })
  }
}
import { ImeBridge, ImeCommand } from '../input/ImeBridge';
import { androidKeycode, isModifierKey } from '../input/KeyMapping';

const KEY_DPAD_UP: number = 19;
const KEY_DPAD_DOWN: number = 20;
const KEY_DPAD_LEFT: number = 21;
const KEY_DPAD_RIGHT: number = 22;
const KEY_TAB: number = 61;
const KEY_ESCAPE: number = 111;
const KEY_PAGE_UP: number = 92;
const KEY_PAGE_DOWN: number = 93;
const KEY_HOME: number = 122;
const KEY_END: number = 123;

function isNavigationKey(androidKey: number): boolean {
  return androidKey === KEY_DPAD_UP || androidKey === KEY_DPAD_DOWN || androidKey === KEY_DPAD_LEFT ||
    androidKey === KEY_DPAD_RIGHT || androidKey === KEY_TAB || androidKey === KEY_ESCAPE ||
    androidKey === KEY_PAGE_UP || androidKey === KEY_PAGE_DOWN || androidKey === KEY_HOME || androidKey === KEY_END;
}

function hasCommandModifier(event: KeyEvent): boolean {
  if (event.getModifierKeyState === undefined) {
    return false;
  }
  return event.getModifierKeyState(['Ctrl']) || event.getModifierKeyState(['Alt']);
}

@Component
export struct KeyboardDock {
  @Prop inputEnabled: boolean;
  onText: (text: string) => void = (text: string) => {
  };
  onDelete: (count: number) => void = (count: number) => {
  };
  onKey: (event: KeyEvent) => void = (event: KeyEvent) => {
  };
  private bridge: ImeBridge = new ImeBridge();

  build() {
    TextInput({ text: '' })
      .id('mirageKb')
      .width(1)
      .height(1)
      .opacity(0.01)
      .caretColor(Color.Transparent)
      .enablePreviewText(false)
      .onWillInsert((info: InsertValue) => {
        if (this.inputEnabled) {
          const commands: ImeCommand[] = this.bridge.insertCommands(info.insertValue);
          for (const command of commands) {
            this.onText(command.text);
          }
        }
        return false;
      })
      .onWillDelete((info: DeleteValue) => {
        if (this.inputEnabled) {
          const commands: ImeCommand[] = this.bridge.deleteCommands(info.deleteValue.length);
          for (const command of commands) {
            this.onDelete(command.count);
          }
        }
        return false;
      })
      .onSubmit(() => {
        if (this.inputEnabled) {
          this.onText('\n');
        }
      })
      .onKeyEvent((event: KeyEvent) => {
        if (!this.inputEnabled) {
          return;
        }
        if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
          return;
        }
        const code = androidKeycode(event.keyCode);
        if (code === 0) {
          return;
        }
        if (isNavigationKey(code) || isModifierKey(code) || hasCommandModifier(event)) {
          this.onKey(event);
          event.stopPropagation();
        }
      })
  }
}
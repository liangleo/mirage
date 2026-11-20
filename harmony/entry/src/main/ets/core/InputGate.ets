export const CTRL_INPUT_ENABLED: number = 3;
export const CTRL_INPUT_DISABLED: number = 4;

export class InputGate {
  reason: string = '';
  private connected: boolean = false;
  private localEnabled: boolean = true;
  private keyboardEnabled: boolean = true;
  private serverEnabled: boolean = true;

  setConnected(value: boolean): void {
    this.connected = value;
  }

  setLocalEnabled(value: boolean): void {
    this.localEnabled = value;
  }

  getLocalEnabled(): boolean {
    return this.localEnabled;
  }

  setKeyboardEnabled(value: boolean): void {
    this.keyboardEnabled = value;
  }

  getServerEnabled(): boolean {
    return this.serverEnabled;
  }

  applyCtrl(code: number, reason: string): void {
    if (code === CTRL_INPUT_ENABLED) {
      this.serverEnabled = true;
      this.reason = '';
    } else if (code === CTRL_INPUT_DISABLED) {
      this.serverEnabled = false;
      this.reason = reason;
    }
  }

  reset(): void {
    this.serverEnabled = true;
    this.reason = '';
  }

  allow(): boolean {
    return this.connected && this.localEnabled && this.serverEnabled;
  }

  allowKeyboard(): boolean {
    return this.connected && this.keyboardEnabled && this.serverEnabled;
  }

  allowRelease(): boolean {
    return this.connected;
  }
}
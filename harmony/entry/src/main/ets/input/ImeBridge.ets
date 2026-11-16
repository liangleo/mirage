export enum ImeCommandKind {
  TEXT,
  DELETE
}

export class ImeCommand {
  kind: ImeCommandKind;
  text: string;
  count: number;

  constructor(kind: ImeCommandKind, text: string = '', count: number = 0) {
    this.kind = kind;
    this.text = text;
    this.count = count;
  }

  static ofText(value: string): ImeCommand {
    return new ImeCommand(ImeCommandKind.TEXT, value, 0);
  }

  static ofDelete(count: number): ImeCommand {
    return new ImeCommand(ImeCommandKind.DELETE, '', count);
  }
}

export class ImeBridge {
  insertCommands(value: string): ImeCommand[] {
    if (value.length === 0) {
      return [];
    }
    return [ImeCommand.ofText(value)];
  }

  deleteCommands(count: number): ImeCommand[] {
    if (count <= 0) {
      return [];
    }
    return [ImeCommand.ofDelete(count)];
  }
}
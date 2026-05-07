declare module 'escpos-usb' {
  export class USB {
    open(callback: (err: any) => void): void;
    write(data: Buffer, callback: (err: any) => void): void;
    close(): void;
  }
}

declare module 'escpos-network' {
  export class Network {
    constructor(address: string, port?: number);
    open(callback: (err: any) => void): void;
    write(data: Buffer, callback: (err: any) => void): void;
    close(): void;
  }
}

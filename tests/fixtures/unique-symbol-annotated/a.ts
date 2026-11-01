const x: unique symbol = Symbol();
class K {
  static readonly Val: unique symbol = Symbol();
  static readonly Other = Symbol();
}

interface Keyed {
  [x]: number;
  [K.Val]: string;
  [K.Other]: boolean;
}

declare const k: Keyed;
export const a: boolean = k[x];
export const b: boolean = k[K.Val];
export const d: number = k[K.Other];

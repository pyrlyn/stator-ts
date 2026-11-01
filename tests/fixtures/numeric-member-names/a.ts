interface I {
  1.0: string;
  0x10: number;
  1e3: boolean;
  2_000: symbol;
  [3.0]: bigint;
}
declare const i: I;
const a: string = i[1];
const b: number = i[16];
const c: boolean = i[1000];
const d: symbol = i[2000];
const e: bigint = i[3];
const k1: keyof I = 1;
const k2: keyof I = 16;
const k3: keyof I = 1000;
const k4: keyof I = 2000;
const k5: keyof I = 3;
const ks: (keyof I)[] = [1, 16, 1000, 2000, 3];

class C {
  1.0 = "x";
  0x10 = 2;
  1e3 = true;
  static 2_000 = 1;
  [3.0]() {
    return 1n;
  }
}
declare const cc: C;
const f: string = cc[1];
const g: number = cc[16];
const h: boolean = cc[1000];
const j: number = C[2000];
const m: bigint = cc[3]();
const o = { 1.0: "a", 0x10: 2 };
const p: string = o[1];
const q: number = o[16];
interface O {
  0xFFFFFFFFFFFFFFFFFF: string;
  0(): void;
}

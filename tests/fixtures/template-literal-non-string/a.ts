type V = `${number}` | `${number}s`;
function ms(value: V): number;
function ms(value: number): string;
function ms(value: V | number): number | string {
  return typeof value === 'string' ? 1 : 'x';
}
ms(1500).nothing;
ms('10s').nothing;
const a: `${number}` = 1500;
const b: V = 15;
const c: `a${string}` = true;
const d: `a${string}` = {};
const e: `a${string}` = null;
const f: `${bigint}` = 1n;
const g: `a${string}` = 'ab';
const h: `a${string}` = `a${a}`;
enum S {
  A = 'ax',
  B = 'bx',
}
const i: `a${string}` = S.A;
const j: `a${string}` = S.B;
function k<T extends string>(x: T): `a${string}` {
  return x;
}

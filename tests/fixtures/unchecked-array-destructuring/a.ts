const xs: number[] = [1];
const [a, b = 2] = xs;
const n1: number = a;
const n2: number = b;
let t: [number, string?] = [1];
const [p, q] = t;
const s1: string = q;
function f([x]: number[]): number { return x; }
const m: Record<string, number> = {};
const { k } = m;
const v: number = k;

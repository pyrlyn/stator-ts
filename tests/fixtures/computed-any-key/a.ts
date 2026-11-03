declare const k: any;
const o = { [k]: 1 };
o[k].nothing;
const a: { x: string } = o;
const s: number = o;
const m = { [k]: 1, b: 'x' };
m[k].nothing;
m[0].nothing;
m['b'].nothing;
m.c;
const n: string = { [k]: 1, [k]: 'y' };
const p = { a: 1 };
p[k];
[1][k].nothing;
'x'[k].nothing;
declare const r: Record<string, boolean>;
r[k].nothing;
declare const t: [number, string];
t[k].nothing;
function g<T>(v: T[], w: T) {
  v[k].nothing;
  w[k];
}
declare const sym: { [s: symbol]: number };
sym[k];

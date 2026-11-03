type O = { x?: number; y: number };
declare const o: O;
if (o.x !== undefined) {
  delete o.x;
  const n: number = o.x;
}
delete o.y;
const p: { a?: { b?: number } } = {};
p.a = {};
delete p.a.b;
const q: { readonly r?: number; s?: string; m(): void; [k: string]: unknown } = { m() {} };
delete q.r;
delete q["s"];
delete q.m;
delete q.other;
delete q["r"];
declare const name1: number;
delete name1;
delete (o.y);
class P {
  #h?: number;
  run() { delete this.#h; }
}
function g<T extends { a?: string; b: string }>(t: T) {
  delete t.a;
  delete t.b;
}

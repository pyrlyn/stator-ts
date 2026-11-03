const m = new Map<string, number>();
const it = m.keys();
const r = it.next();
if (r.done) {
  const v: undefined = r.value;
  const w: number = r.value;
}
function* g() { yield 1; return "x"; }
const s = g().next();
if (s.done) { const n: number = s.value; }
const a = [1][Symbol.iterator]().next();
const z: string = a.value;

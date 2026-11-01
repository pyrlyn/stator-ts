declare const a: boolean;
declare const list: readonly string[];
function f() {
  let i;
  if (a) {
    i = 1;
  } else if (!a) {
    i = list.length;
  } else {
    i = 2;
  }
  const x: never = i;
  const y: never = list[i];
}
function g() {
  let i: number;
  if (a) {
    i = 1;
  } else {
    i = 2;
    if (i > 0) {
      return;
    }
  }
  const y: never = list[i];
}
function h() {
  let i;
  if (a) {
    i = 'x';
  } else {
    i = 2;
  }
  const y: never = i;
  i = true;
  const z: never = i;
}
function closures() {
  let c;
  c = 1;
  const f1 = () => c;
  const f2 = () => c;
  let d;
  d = 'x';
  function inner() { return d; }
  const r1: never = f1();
}
function compound() {
  let s;
  s = 'a';
  s += 1;
  const t: never = s;
  let n;
  n = 1;
  n++;
  const u: never = n;
}
function narrowing() {
  let v;
  if (a) v = 1;
  const w: never = v;
  if (v) {
    const y: never = v;
  }
  let nul = null;
  const q: never = nul;
  nul = 2;
  const r: never = nul;
  let und = undefined;
  const q2: never = und;
}
function loops(xs: string[]) {
  let last;
  for (const x of xs) {
    const p: never = last;
    last = x;
  }
  const z: never = last;
  let cnt;
  while (a) {
    cnt = 1;
  }
  const w: never = cnt;
}
function assignedFn() {
  let cb;
  cb = (e) => e;
  let o;
  o = { a: 1 };
  o.a;
  o.b;
  let lit;
  lit = 'x';
  const m: 'x' = lit;
}
var top;
top = 1;
const useTop: never = top;
export let ex;
declare let amb;
let tup;
[tup] = [1];
const v3: never = tup;
declare function $<T extends HTMLElement>(d: string): T;
function generic() {
  let icon;
  icon = $('.x');
  const z: never = icon;
}
declare const val: { text: string } | undefined;
function pastTruthyTest() {
  let vt;
  try {
    vt = val;
  } catch {
  }
  if (!vt) {
    return;
  }
  const f = () => { const q: never = vt; };
}
function oneBranch() {
  let vt;
  if (val) {
    vt = val;
  }
  const f = () => { const q: never = vt; };
}

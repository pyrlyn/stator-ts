const kind = (b: number) => {
  if (b > 1) { return 'a'; } else if (b < 0) { return 'b'; }
  return 'c';
};
const a: 'a' | 'b' | 'c' = kind(1);
const b: 'a' = kind(1);
const one = (b: number) => { return 'a'; };
const c: 'a' = one(1);
function n(b: number) { if (b) { return 1; } return 2; }
const d: 1 | 2 = n(1);
function t(b: number) { return b ? true : false; }
const e: boolean = t(1);

// An `infer` name is taken in the true branch alone, so the check and the false branch still see `T`.
type First<T> = T extends `${infer T}@${string}` ? T : [T];
const a: First<'x@y'> = 'x';
const b: First<'x'> = ['x'];
const c: First<'x'> = 'x';
const d: First<'x@y'> = 'y';
type Second<T> = T extends [infer T] ? { in: T } : { out: T };
const e: Second<[1]> = { in: 1 };
const f: Second<2> = { out: 2 };
const g: Second<2> = { in: 2 };

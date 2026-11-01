enum Str {
  A = 'a',
  B = 'b',
}
enum Num {
  A,
  B,
}
enum Mixed {
  A = 'a',
  B = 1,
}
declare const seed: string;
enum Computed {
  A = seed.length,
}
enum Empty {}
const enum Frozen {
  A = 'a',
}
enum Merged {
  A = 'a',
}
namespace Merged {
  export const n = 1;
}
enum Words {
  A = 'a',
}
namespace Words {
  export const w = 'w';
}

declare function values<T>(o: { [k: string]: T }): T;

const str: Str = values(Str);
const num: Num = values(Num);
const mixed: Mixed = values(Mixed);
const computed: Computed = values(Computed);
const merged: Merged = values(Merged);
const words: Words | 'w' = values(Words);

for (const v of Object.values(Str)) {
  const s: Str = v;
}
for (const v of Object.values(Num)) {
  const n: Num = v;
}

const strRecord: Record<string, Str> = Str;
const numRecord: Record<string, Num> = Num;
const mixedRecord: Record<string, Mixed> = Mixed;
const names: Record<string, string> = Num;
const byNumber: { [n: number]: string } = Str;

const a = Str[0];
const b = Num[0];
const c = Mixed[0];
const d = Computed[0];
const e = Empty[0];
const f = Merged[0];
const g = Words[0];
const h = Frozen[0];
const i = Frozen['A'];
const j = Frozen[`A`];

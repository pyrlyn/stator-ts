interface DA { kind: 'a'; opts: string[] }
interface DB { kind: 'b'; other: number }
declare function eq<T>(actual: unknown, expected: T): asserts actual is T;
declare function resOf(): { data?: DA | DB } | undefined;
function af() {
  const r = resOf();
  eq(r?.data?.kind, 'a');
  const n: string[] = r.data.opts;
  r.data.other;
}
function af2(r: DA | DB) {
  eq(r.kind, 'a');
  r.opts;
  r.other;
}

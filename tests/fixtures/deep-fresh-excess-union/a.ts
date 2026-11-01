declare function dse<T>(actual: unknown, expected: T): T;
enum K { U, De, N }
const r = dse([] as { id: string }[], [
  { id: 'a', reason: { type: K.U } },
  { id: 'b', reason: { type: K.De, source: 'user' } },
  { id: 'c', reason: { type: K.N, reason: 'x' } },
]);
const a: string | undefined = r[0].reason.source;
const b: number = r[0].reason.source;
declare function st<T>(a: T, b: T): void;
const conf: { id: string; reason: { type: K } }[] = [];
st(conf, [{ id: 'a', reason: { type: K.U } }, { id: 'b', reason: { type: K.De, source: 'user' } }]);

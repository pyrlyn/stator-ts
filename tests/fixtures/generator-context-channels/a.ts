function* g(): Generator<'a' | 'b', 'r', number> {
  const n: number = yield 'a';
  const s: string = yield 'b';
  yield 'c';
  return 'r';
}
type Fn = () => Generator<{ k: 'x' }, { d: 'y' }, string>;
const f: Fn = function* () {
  const v = yield { k: 'x' };
  const w: number = v;
  return { d: 'y' };
};
async function* ag(): AsyncGenerator<'p', void, unknown> {
  yield 'p';
  yield 'q';
}
function* it(): Iterator<number> { yield 1; yield 's'; }
function* itb(): IterableIterator<'z'> { yield 'z'; }

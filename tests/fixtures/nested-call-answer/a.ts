declare function id<T>(x: T): T;
declare function pick<T>(a: T[], f: (x: T) => boolean): T;
const r = id(id(id(pick([1, 2], x => x > 1))));
const s: string = r;
const t = pick([id('a')], x => x.length > id(0));
const u: number = t;
class Wrap<T> { constructor(public v: T, f: (x: T) => void) {} }
const w = new Wrap(id(1), x => { const n: number = x; });
const o: Wrap<string> = w;

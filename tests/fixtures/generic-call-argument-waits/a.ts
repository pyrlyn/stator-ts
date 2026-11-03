type Mapper<T, U> = (x: T) => U;
declare function wrap<T, U>(cb: Mapper<T, U>): Mapper<T, U>;
declare function combine<A, B, C>(f: (x: A) => B, g: (x: B) => C): (x: A) => C;
declare function identity<T>(x: T): T;

const a: (s: string) => number = combine(identity, wrap(s => s.length));
const b = ["a", "b"].map(combine(identity, wrap(s => s.length)));
const c: number[] = b;
const d: string[] = b;

// The wait is for functions a generic call makes, not for what its type arguments fix.
const e = combine(identity, wrap<string, number>(s => s.length));
const f: (x: number) => number = e;

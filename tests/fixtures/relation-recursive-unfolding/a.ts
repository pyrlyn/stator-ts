interface Grow<T> { value: T; next: Grow<Grow<T>> }
declare const gs: Grow<string>;
const a: Grow<string> = gs;
const b: Grow<number> = gs;
interface Nest<T> { inner: Nest<T[]>; tag: T }
declare const ns: Nest<string>;
const c: Nest<string> = ns;
const d: Nest<number> = ns;

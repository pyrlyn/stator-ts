interface Reader<T> { read(): T }
interface Writer<T> { write: (x: T) => void }
interface Both<T> { get(): T; set: (x: T) => void }
interface Phantom<T> { tag: string }
declare const rs: Reader<'a'>;
const r1: Reader<string> = rs;
const r2: Reader<number> = rs;
declare const ws: Writer<string>;
const w1: Writer<'a'> = ws;
const w2: Writer<number> = ws;
declare const bs: Both<'a'>;
const b1: Both<string> = bs;
declare const ph: Phantom<string>;
const p1: Phantom<number> = ph;
interface In<in T> { f(x: T): void }
interface Out<out T> { v(): T }
interface InOut<in out T> { v: T }
declare const i1: In<string>;
const i2: In<'a'> = i1;
const i3: In<number> = i1;
declare const o1: Out<'a'>;
const o2: Out<string> = o1;
declare const io: InOut<'a'>;
const io1: InOut<string> = io;

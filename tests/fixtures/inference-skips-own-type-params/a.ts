interface P<T> { v: T; }
interface C<T> extends P<T> { c(): void }
declare function id<T>(x: P<T>): T;
declare const c: C<void>;
const r: number = id(c);
interface P2<T> { then<R = T>(f: (x: T) => R): P2<R> }
interface C2<T> extends P2<T> { c(): void }
declare function id2<T>(x: P2<T>): T;
declare const c2: C2<void>;
const r2: number = id2(c2);
interface P3<T> { then(f: (x: T) => void): void }
interface C3<T> extends P3<T> { c(): void }
declare function id3<T>(x: P3<T>): T;
declare const c3: C3<void>;
const r3: number = id3(c3);
interface C4<T> extends Promise<T> { c(): void }
declare function id4<T>(x: Promise<T>): T;
declare const c4: C4<void>;
const r4: number = id4(c4);
declare const c5: C4<string>;
const r5: number = id4(c5);

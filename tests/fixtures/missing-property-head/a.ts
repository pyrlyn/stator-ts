interface M { a: 1; b: 2; c: 3 }
interface L extends M { d: 4; e: 5; f: 6 }
declare function one(a: { id: number; name?: string }): void;
declare function many(m: M): void;
declare function lots(m: L): void;
declare const v: { name: string };
one({ name: "hello" });
one(v);
many(v);
lots(v);
interface A { a: 1 }
interface B { b: 2 }
declare class Box<T extends A> { x: T }
declare var box: Box<B>;
class Base { x = 1; y = 2; }
class Empty extends Base {}
const e: Empty = {} as { z: 1 };
class P1 { private p = 1; }
class P2 { private p = 2; }
declare let never: P1 & P2;
never = {};
export {};

declare const one: { get(): number[] } | { get(): any[] };
let elems = one.get();
elems.forEach((e: string) => e.length);
declare const two: { get(): 'a' } | { get(): string };
const v = two.get();
const w: never = v;
class B { b = 1 }
class D extends B { d = 2 }
declare const three: { get(): B } | { get(): D };
const x: never = three.get();
declare const four: (new () => D) | (new () => B);
const y: never = new four();

class C<T> {
    static x: T;
    static m(a: T): T { let v: T; return a; }
    static get g(): T { return null as any; }
    static { let q: T; }
    static f = (y: T) => y;
    inst: T;
    method() { class Inner { static z: T; } }
}
interface I<T> { a: T }
export {};

// A method's own type parameter shadows the class one.
class D<T> {
    static pick<T>(a: T): T { return a; }
}
const E = class<U> {
    static u: U;
};

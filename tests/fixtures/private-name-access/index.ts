class A {
    #field = 1;
    #method() { return ""; }
    static #count = 0;
    get #acc() { return 1; }
    read(other: A) {
        function inner() { return other.#field; }
        return this.#field + other.#acc + A.#count + inner();
    }
}
new A().#field;
new A().#method();
A.#count;

function outside(a: A) {
    return a.#acc;
}

class B extends A {
    look() { return this.#field; }
}

class Outer {
    #x = 1;
    m(o: Outer) {
        class Inner {
            #x = "s";
            n() { return o.#x; }
        }
        return new Inner();
    }
}

const C = class Named {
    #m() {}
    static run(c: { x: number }) { return c; }
};
new C().#m();

class Generic<T> {
    #value: T;
    constructor(v: T) { this.#value = v; }
    same(o: Generic<string>) { return o.#value; }
}
new Generic(1).#value;

class StaticBase {
    static #secret = 1;
    static peek(x: typeof StaticChild) {
        return x.#secret;
    }
}
class StaticChild extends StaticBase {}

class Parent {
    #foo = 3;
    read() { return new Child().#foo; }
}
class Child extends Parent {
    #foo = "foo";
}

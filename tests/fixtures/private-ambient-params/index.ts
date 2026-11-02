// Nothing outside sees a private member of an ambient class, so its untyped parameters are fine.
declare class A {
    private constructor(a);
    private hidden(b): void;
    public shown(c): void;
}

class B {
    private hidden(d) { }
}

export { A, B };

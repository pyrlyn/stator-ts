// With no annotation on either accessor and no getter body, the property is `any`.
interface I {
    get a();
    set b(v);
    get c();
    set c(v);
    get d(): number;
    set d(v);
}

declare class A {
    get e();
    private set f(v);
}

export class B {
    set g(v) { }
    get h() { return 0; }
    set h(v) { }
}

export type { I, A };

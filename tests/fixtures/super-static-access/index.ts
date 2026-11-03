declare class Base {
    static method(...args: any[]): void;
    im(): void;
}
const method = "method";
class C extends Base {
    static {
        super.method();
        super["method"]();
        super[method]();
    }
    static s() { super["method"](); }
    i() { super["im"](); }
}
class D extends Base {
    static {
        super["im"]();
        const m: number = super.method;
    }
}

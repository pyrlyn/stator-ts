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
    i() { super["method"](); }
}
interface I { foof: number }
declare const i: I;
i["foo"];
class A { public static "\""() {} static y = 1 }
const a = new A();
a["\""];
a['y'];

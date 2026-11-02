class C1 {
    p1!: number;
}
class C2 extends C1 {
    p2!: number;
}
declare let v: C2 | string;
if (v.constructor === C1) {
    v.p1;
}
if (v.constructor === C2) {
    v.p2;
}
if (v["constructor"] === C2) {
    v.p2;
}
if (v.constructor !== C2) {
    v.p2;
} else {
    v.p2;
}
declare let n: number | string;
if (n.constructor === Number) {
    n.toFixed();
}
class B {
    static a = 1;
}
class D extends B {
    static {
        super.a;
        super.missing;
    }
}

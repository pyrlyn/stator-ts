interface X { a: string; b?: number }
declare const x: X | undefined;
declare const flag: boolean;
const v1 = x ?? {};
const p1: number = v1;
const v2 = flag ? x! : {};
const p2: number = v2;
const { a, b } = x ?? {};
const p3: number = a;
const p4: number = b;
const { a: aa = 'q' } = x || {};
const p5: number = aa;
const [e1] = x ? [x] : [];
const p6: number = e1;
function f(y: X | undefined) {
    const { a: a1 } = y ?? {};
    return a1;
}
const v3 = [x ?? {}];
const p7: number = v3;
const v4 = { k: x ?? {} };
const p8: number = v4;

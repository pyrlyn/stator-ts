interface H { hover?: (a: string, b: number) => void; deep?: { fn?: () => string }; name: string | null }
declare const h: H;

function narrowed() {
    if (!h.hover) throw 0;
    const r: Parameters<typeof h.hover>[1] = 1;
    const wrong: Parameters<typeof h.hover>[1] = 'x';
    return [r, wrong];
}

function chained() {
    if (h.deep?.fn) {
        type T = ReturnType<typeof h.deep.fn>;
        const s: T = 'a';
        return s;
    }
    const before: ReturnType<typeof h.deep.fn> = 'a';
    return before;
}

function kept(o: { v: string | number }) {
    if (typeof o.v === 'string') {
        const a: typeof o.v = 'x';
        const b: typeof o.v = 1;
        o = { v: 1 };
        const e: typeof o.v = 1;
        return [a, b, e];
    }
    const n: typeof o.v = 'no';
    return n;
}

if (h.name !== null) {
    let s: typeof h.name = 'a';
    s = null;
}
let opened: typeof h.hover;
opened = undefined;
let absent: typeof h.nothing;
namespace N { export const k = 1; export namespace M { export let z: string | undefined; } }
enum E { A, B }
const k1: typeof N.k = 1;
const k2: typeof N.k = 2;
const e1: typeof E.A = E.B;
if (N.M.z) {
    const z1: typeof N.M.z = 'a';
    const z2: typeof N.M.z = undefined;
}
class C { private p = 1; protected q = 2; static s = 3; }
declare const c1: C;
let p1: typeof c1.p;
let p2: typeof c1.q;
let p3: typeof C.s;

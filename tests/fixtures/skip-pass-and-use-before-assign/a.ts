declare function pair<T>(v: T, g: (x: T) => void): T;

const one = pair(od(), x => x.n());
const w: number = one.n();
const v = (d: ReturnType<typeof od>) => d.s;
const vv: number = v(od());

const two = pair(later.f(), x => x.length);
const s: string = two;
const later = { f: (x = 'a') => x };

const three = pair(viaLocal.m(), x => x);
const n: number = three;
const viaLocal = { m: (x = 1) => x };

function od() {
    return { s: async (u: string, r = u.length) => r, n: (x = 1) => x };
}

declare const flag: boolean;
if (flag) {
    var maybe = 1;
}
const read: number = maybe;

function hoisted() {
    const a: number = late;
    var late = 2;
    return a + late;
}

function fine() {
    var early = 3;
    for (var i = 0; i < early; i++) early--;
    return () => early + i;
}

var outerVar = 1;
var unset: number;
let unsetLet: string;
namespace Inner {
    const a: number = outerVar;
    const b: number = unset;
    const c1: string = unsetLet;
    var own = 2;
    export const d: number = own;
    export const e: number = laterInside;
    var laterInside = 3;
}

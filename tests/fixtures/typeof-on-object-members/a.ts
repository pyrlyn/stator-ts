interface Empty {}
interface Weak { a?: number }
interface Named { a: number }
declare const e: Empty;
declare const w: Weak;
declare const n: Named;
declare const s: String;
declare const u1: Empty | number;
declare const u2: Named | Empty;
declare const u3: String | number;
declare const u4: Weak | number;
declare const u5: Number | string;
declare const u6: Object | number;
declare const u7: Empty | undefined;

function f1() { if (typeof e === "string") { const z: "z" = e; } }
function f2() { if (typeof w === "string") { const z: "z" = w; } }
function f3() { if (typeof n === "string") { const z: "z" = n; } }
function f4() { if (typeof s === "string") { const z: "z" = s; } }
function f5() { if (typeof u1 === "string") { const z: "z" = u1; } }
function f6() { if (typeof u2 === "string") { const z: "z" = u2; } }
function f7() { if (typeof u3 === "string") { const z: "z" = u3; } }
function f8() { if (typeof u4 === "string") { const z: "z" = u4; } }
function f9() { if (typeof u5 === "string") { const z: "z" = u5; } }
function f10() { if (typeof u6 === "string") { const z: "z" = u6; } }
function f11() { if (typeof u7 === "string") { const z: "z" = u7; } }
function f12() { if (typeof e === "number") { const z: "z" = e; } }
function f13() { if (typeof e === "boolean") { const z: "z" = e; } }
function f14() { if (typeof e === "function") { const z: "z" = e; } }
function f15() { if (typeof e === "object") { const z: "z" = e; } }
function f16() { if (typeof e === "undefined") { const z: "z" = e; } }
function f17() { if (typeof e === "symbol") { const z: "z" = e; } }
function f18() { if (typeof e === "bigint") { const z: "z" = e; } }
function f19() { if (typeof n === "object") { const z: "z" = n; } }
function f20() { if (typeof n === "function") { const z: "z" = n; } }
function f21() { if (typeof u7 === "undefined") { const z: "z" = u7; } }
function f22() { if (typeof u2 === "function") { const z: "z" = u2; } }
function f23() { if (typeof e !== "string") { const z: "z" = e; } }
function f24() { if (typeof u1 !== "number") { const z: "z" = u1; } }
function f25() { if (typeof s !== "string") { const z: "z" = s; } }
function f26(x: Empty & Named) { if (typeof x === "string") { const z: "z" = x; } }
function f27(x: { v: Empty | string[] }) { if (typeof x.v === "string") { const z: number = x.v.length; const y: "z" = x.v; } }
declare const anon: {};
function f28() { if (typeof anon === "object") { const z: "z" = anon; } }
function f29() { if (typeof anon === "string") { const z: "z" = anon; } }
function f30(x: Empty | Named) { if (typeof x === "object") { const z: "z" = x; } }
function f31<S extends object>(reducer: (() => void) | Record<keyof S, () => void>) {
    let root: () => void;
    if (typeof reducer === "function") {
        root = reducer;
    }
}

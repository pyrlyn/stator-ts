declare function cond(): boolean;
declare const s: string;
function a() {
    let x;
    x ??= 1;
    const y: string = x;
}
function b() {
    let x;
    x ||= s;
    const y: number = x;
}
function c() {
    let x;
    x = s;
    x &&= 1;
    const y: boolean = x;
}
function d() {
    let x;
    x += 1;
    const y: boolean = x;
}
function e() {
    let x = null;
    x ??= s;
    () => x;
}
function f(init: (v: () => void) => void) {
    let x;
    init(v => { x = v; });
    x!();
    const q: number = x!;
}
function g(ns: number[]) {
    let last;
    for (const n of ns) last = n;
    const q: string = last!;
    last;
}
for (; false;) {
    let u;
    () => u;
}
for (let v; false;) {
    () => v;
}

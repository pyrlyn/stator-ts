interface Tag { t: string }
interface Other { o?: number }
type Wrapped<T> = T & { id?: number };
declare const a: Tag & Other;
declare const b: (Tag & Other) | undefined;
declare const c: Wrapped<{ [K in "x"]: number }> | Wrapped<{ [K in "x"]: number }>[] | undefined;
declare const d: string & { brand: 1 };
declare const e: "" & { brand: 1 };
declare const f: "a" & { brand: 1 };
declare const g: (string & { brand: 1 }) | undefined;
declare const h: {} & { x?: number };
declare const i: 0 & { brand: 1 };
declare const j: boolean & { brand: 1 };
declare const k: Function & Tag;
function fa() { if (!a) { const z: "z" = a; } else { const z: "z" = a; } }
function fb() { if (!b) { const z: "z" = b; } else { const z: "z" = b; } }
function fc() { if (!c) { const z: "z" = c; } else { const z: "z" = c; } }
function fd() { if (!d) { const z: "z" = d; } else { const z: "z" = d; } }
function fe() { if (!e) { const z: "z" = e; } else { const z: "z" = e; } }
function ff() { if (!f) { const z: "z" = f; } else { const z: "z" = f; } }
function fg() { if (!g) { const z: "z" = g; } else { const z: "z" = g; } }
function fh() { if (!h) { const z: "z" = h; } else { const z: "z" = h; } }
function fi() { if (!i) { const z: "z" = i; } else { const z: "z" = i; } }
function fj() { if (!j) { const z: "z" = j; } else { const z: "z" = j; } }
function fk() { if (!k) { const z: "z" = k; } else { const z: "z" = k; } }
function gen<T>(x: T & Tag, y: T & { a?: 1 }, w: T & {}) {
    if (!x) { const z: "z" = x; } else { const z: "z" = x; }
    if (!y) { const z: "z" = y; } else { const z: "z" = y; }
    if (!w) { const z: "z" = w; } else { const z: "z" = w; }
}
function dto(data: Wrapped<{ [K in "x"]: number }> | Wrapped<{ [K in "x"]: number }>[] | undefined): string | undefined {
    if (!data) return data;
    return "a";
}

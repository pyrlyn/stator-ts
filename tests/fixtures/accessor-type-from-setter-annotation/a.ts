interface Box { sel: Readonly<[number, number]> | undefined; v: string }
declare const flag: boolean;
class Impl implements Box {
    get sel() {
        if (flag) return undefined;
        return [1, 2];
    }
    set sel(x: Readonly<[number, number]>) { }
    get v() { return 'a'; }
    set v(x) { }
}
const b: Box = new Impl();
const r: number = new Impl().sel;
class Annotated {
    get a(): string | undefined { return ''; }
    set a(x: string | undefined) { }
    get n() { return 1; }
    set n(x: number) { }
    set w(x: number) { }
    get m() { return 1; }
    set m(x) { }
}
const a1: number = new Annotated().a;
const a2: string = new Annotated().n;
const a3: string = new Annotated().w;
const a4: string = new Annotated().m;

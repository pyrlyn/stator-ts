interface Obs<T> { read(): T; map<N>(f: (v: T) => N): Obs<N>; }
declare function derived<T>(f: () => T): Obs<T>;
declare function mapAll<I, O>(items: Obs<readonly I[]>, map: (i: I) => O): Obs<readonly O[]>;
function early(a: A) { return a.count.read() + a.keys.read().length; }
export class A {
    readonly items;
    readonly keys;
    readonly count;
    constructor(source: Obs<readonly { key: string }[] | undefined>) {
        this.count = derived(() => this.items.read()?.length ?? 0);
        this.items = derived(() => source.read());
        this.keys = mapAll(this.items.map(r => r ?? []), x => x.key);
    }
}
export class B<T> {
    value;
    constructor(x: T) { this.value = [x]; }
}
const b: "z" = new B(1).value;
const k: "z" = new A(null!).keys;
class C {
    f;
    constructor() { this.f = (x) => 1; }
}
class D {
    g = (x: number) => x;
    h: (x: number) => number;
    constructor() {
        this.g = x => x;
        this.h = x => x;
    }
}
class E {
    list;
    constructor() {
        this.list = [];
        this.list = ["a"];
    }
}
const l: "z" = new E().list;

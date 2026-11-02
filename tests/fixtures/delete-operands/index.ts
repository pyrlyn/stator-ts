interface Box {
    a: number;
    b?: string;
    c: number | undefined;
    readonly d?: number;
    e: any;
    f: unknown;
    [k: string]: unknown;
}

declare const box: Box;
declare let n: number;

delete box.a;
delete box.b;
delete box.c;
delete box.d;
delete box.e;
delete box.f;
delete box["a"];
delete box["b"];
delete box.other;
delete (box.a);
delete n;
delete 1;
delete "x";
delete `t`;
delete (n + 1);
delete box?.a;

export class K<T, U extends string | undefined> {
    #p?: number;
    t!: T;
    u!: U;
    v!: void;
    m() {
        delete this.#p;
        delete this.t;
        delete this.u;
        delete this.v;
    }
}

const tuple: [number, string?] = [1];
delete tuple[0];
delete tuple[1];
export {};

declare const frozen: Readonly<{ foo: string; baz?: string }>;
const { foo, ...rest } = frozen;
delete rest.baz;
rest.baz = foo;
delete frozen.baz;

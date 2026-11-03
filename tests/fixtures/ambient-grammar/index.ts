declare function implemented(): void {
    return;
}

declare namespace Statements {
    interface I {};
    let a: number;
}

declare namespace Loops {
    export var x: number;
    while (true) {}
    if (x) {}
}

declare namespace Debugging {
    debugger;
}

enum E { A = 1 }

declare const ok = 1;
declare const negative = -1;
declare const fromEnum = E.A;
declare const viaIndex = E["A"];
declare const big = 10n;
declare const typed: number = 1;
declare let mutable = 1;
declare const computed = 1 + 1;
declare var list = [1];

declare class Fields {
    readonly ok = 1;
    plain = 1;
    method(): void {}
    get value(): number { return 1; }
}

export class Members {
    declare field: number;
    declare readonly literal: 1;
}

type WithAccessor = {
    get size(): number { return 0; }
};

interface WithSetter {
    set size(v: number) { }
}

export type { WithAccessor, WithSetter };

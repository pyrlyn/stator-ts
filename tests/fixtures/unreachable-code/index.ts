// A run of dead statements is one error; a namespace inside it stays quiet.
function run(): void {
    return;
    const a = 1;
    namespace N {
        while (true);
        export let b = a;
    }
}

// Types, `var` without initializers, functions and const enums emit nothing to reach.
function quiet(): void {
    throw new Error();
    var v;
    type T = string;
    function g(): T { return ""; }
    const enum E { A }
    { }
}

// Only bare `true` and `false` are constants.
function negated(): number {
    if (!true) return 1;
    else return 2;
}

function fail(message: string): never {
    throw new Error(message);
}

function afterNever(): void {
    fail("x");
    console.log("dead");
}

function exhaustive(x: 1 | 2): string {
    switch (x) {
        case 1: return "a";
        case 2: return "b";
    }
    x;
}

// A default that throws makes only its own path dead.
function withDefault(p: unknown = (() => { throw new Error(); })()): void {
    console.log(p);
}

export { run, quiet, negated, afterNever, exhaustive, withDefault };

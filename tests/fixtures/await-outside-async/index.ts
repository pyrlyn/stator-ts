declare const p: Promise<number>;
declare const d: AsyncDisposable;
declare const it: AsyncIterable<number>;

function plain() {
    await p;
    const n = await 1;
    for await (const x of it) {}
    await using r = d;
}

async function outer() {
    function inner() {
        await p;
    }
    const arrow = () => await p;
    class C {
        x = await p;
    }
}

async function withParam(a = await p) {}
function syncParam(a = await p) {}

class S {
    static {
        await p;
        await using r = d;
        for await (const x of it) {}
    }
}

await p;
await using top = d;
for await (const x of it) {}
await (p);

export {};

declare const k: string;
export class Exported {
    [await k]() {}
}
class Local {
    [await k]() {}
}
namespace N {
    class Inner {
        [await k]() {}
    }
}
async function computed() {
    class M {
        [await k]() {}
    }
}

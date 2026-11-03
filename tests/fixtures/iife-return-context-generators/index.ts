// An immediately invoked function returns into whatever its call is expected to give.
const f: (x: string) => number = (() => x => x.length)();

const g: Promise<(x: string) => number> = (async () => x => x.length)();

function* outer(): Iterator<Iterable<(x: string) => number>> {
    yield (function* () {
        yield x => x.length;
    })();
}

const h = (() => x => x)();

export { f, g, outer, h };

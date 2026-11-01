interface Move { readonly n: number; readonly values?: { readonly source: Readonly<Record<string, string | null>>; readonly target: Readonly<Record<string, string | null>> } }
declare const flag: boolean;
declare const other: boolean;
declare function take(m: Move): void;
declare const moved: { a: string[] } | undefined;

const artifactValues: Move['values'] = moved && {
    source: flag ? {} : { k: moved.a.length > 0 ? 'x' : null },
    target: { k: 'y' },
};
const p0: number = artifactValues;
const p00: number = { ...artifactValues?.source };
async function commit(v: string) {
    const merge = flag || other ? {
        source: flag ? { configValues: v } : {},
        target: other ? { configValues: v } : {},
    } : undefined;
    const p1: number = artifactValues;
    const p2: number = { ...artifactValues?.source };
    const p3: number = { ...merge?.source };
    const p4: number = { ...artifactValues?.source, ...merge?.source };
    const p5: number = artifactValues || merge;
    const p6: number = artifactValues || merge ? { ...artifactValues?.source } : 1;
    const p7: number = artifactValues || merge ? { ...merge?.source } : 1;
    const p8: number = artifactValues || merge ? { ...artifactValues?.source, ...merge?.source } : 1;
}
interface Move { readonly n: number; readonly values?: { readonly source: Readonly<Record<string, string | null>>; readonly target: Readonly<Record<string, string | null>> } }
declare function take(m: Move): void;
function second(v: string) {
    const merge = flag ? { source: flag ? { configValues: v } : {}, target: other ? { configValues: v } : {} } : undefined;
    const move = {
        n: 1,
        values: artifactValues || merge ? {
            source: { ...artifactValues?.source, ...merge?.source },
            target: { ...artifactValues?.target, ...merge?.target },
        } : undefined,
    };
    const shown: number = move;
    take(move);
    const widened = { ...artifactValues?.source, ...merge?.source };
    const w1: number = widened;
    const plain = flag ? {} : { a: 1 };
    const w2: number = plain;
    const spreadThenLit = flag ? { ...merge?.source } : { z: 1 };
    const w3: number = spreadThenLit;
}

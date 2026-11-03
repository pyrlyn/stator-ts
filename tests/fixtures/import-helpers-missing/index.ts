// Each helper is reported once per file, at the first syntax that needs it.
import * as ns from "./other";
import def from "./other";
import { default as alsoDef } from "./other";
export * from "./other";
export * as again from "./other";
export { default as reexported } from "./other";

async function first() {}
async function second() {}
async function* stream(): AsyncGenerator<number> {
    yield* stream();
    for await (const x of stream()) {}
}

const { a, ...rest } = { a: 1, b: 2 };
let b: number;
let others: object;
({ a: b, ...others } = { a: 1, b: 2 });

class Box {
    #value = 1;
    read() {
        this.#value = this.#value + 1;
        this.#value++;
        return #value in this;
    }
}

declare function dec(...args: any[]): any;

@dec
class Decorated {
    @dec method(@dec arg: string) {}
}

export function useAll() {
    return [ns, b, def, alsoDef, rest, others, first, second, Box, Decorated];
}

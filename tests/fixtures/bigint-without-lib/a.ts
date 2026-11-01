// Without the ES2020 lib there is no `BigInt` interface, which leaves a bigint with no members
// rather than with an unknown shape.
declare function test<A, B extends A>(): void;
declare const big: bigint;

test<{ t?: string }, object>();
test<{ t?: string }, bigint>();

const weak: { t?: string } = big;
const empty: {} = big;
const required: { t: string } = big;

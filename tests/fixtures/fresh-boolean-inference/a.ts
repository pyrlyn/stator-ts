declare function same<T>(a: T, b: T): T;

// A declared `boolean` narrowed by its initializer can still widen back.
const flag: boolean = false;
const flags: boolean[] = [];
const merged = same(flags, [flag]);
const wrong: string = merged;

// Parameters that heard nothing keep their literals through the constraint.
const frozen = Object.freeze({ kind: 'a', count: 1 });
const kind: 'a' = frozen.kind;
const count: 1 = frozen.count;
const tooNarrow: 'b' = frozen.kind;

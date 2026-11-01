declare function first<T>(xs: readonly T[]): T;
declare const names: string[];
const a: string = first(names);
const b: number = first(names);
const c: string = first(['a'] as const);
declare function keep<T>(xs: ReadonlyArray<T | undefined>): T[];
declare const maybe: (string | undefined)[];
const d: string[] = keep(maybe);
const e: number[] = keep(maybe);

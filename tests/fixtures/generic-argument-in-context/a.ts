function isDefined<T>(arg: T | null | undefined): arg is T { return arg !== undefined && arg !== null; }
declare const exact: (string | undefined)[];
declare function take(rules: string[]): void;
if (exact.every(isDefined)) {
  take(exact);
}
const kept = exact.filter(isDefined);
const bad1: never = kept;
declare function ev<S extends string | undefined>(p: (v: string | undefined) => v is S): S;
const bad2: never = ev(isDefined);
declare function id<T>(x: T): T;
const bad3: never = [1, 2].map(id);
declare function invoke<R, TS extends any[] = []>(fn: (a: number, ...args: TS) => R, ...args: TS): R;
declare function pass<T extends string>(a: number, x: T): T;
const bad4: never = invoke(pass, 'x');

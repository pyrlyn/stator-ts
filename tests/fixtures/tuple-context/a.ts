declare function pair<T extends [unknown, unknown]>(x: T): T;
const a = pair([1, "a"]);
const n: string = a[0];
const t: [number, string] = [1, 2];
const u: readonly [number, ...string[]] = [1, "a", 3];
declare function rest(...xs: [number, string?]): void;
rest(1, "a");
rest(1, 2);
rest(...([1, "a"] as [number, string]));
rest(...([1, 2] as [number, number]));
declare function spread(a: number, ...b: string[]): void;
const args: [number, string, string] = [1, "a", "b"];
spread(...args);
const bad: [string, number] = ["a", 1];
spread(...bad);
function* gn(): Generator<number, void, number> { const x: string = yield 1; }
gn().next("x");
gn().next(1);

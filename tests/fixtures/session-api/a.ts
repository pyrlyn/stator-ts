interface Box<T extends string = string> {
  value: T;
  get(): T;
}
interface Named extends Box<"n"> {
  name: string;
}
type Alias = Box<"a">;
declare const named: Named;
declare const alias: Alias;
declare function rests(a: number, ...rest: [string, boolean?]): void;
declare function constrained<T extends string>(x: T): T;
function recurse() {
  return recurse;
}

const t1 = named;
const t2 = alias;
const t3 = rests;
const t4 = constrained;
const t5 = recurse;
const t6 = { ...{ b: 1, a: 2 }, c: 3 };
const t7 = named.get();
const t8 = constrained("k");
const t9 = missing;
const t10 = named.value;
const t11 = [1, "a"] as const;
const t12 = { "a-b": 1 };
const t13 = class {
  static s = 1;
};

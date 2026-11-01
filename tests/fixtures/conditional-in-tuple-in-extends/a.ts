export type Strict<T, U extends [U] extends [
	U extends unknown ? ([T] extends [Exclude<T, U>] ? never : U) : never,
] ? unknown : never> = Exclude<T, U>;

type Flat<T> = T extends [infer H extends string ? H : never, ...infer R] ? [H, R] : never;

export const a: Strict<"a" | "b", "a"> = "b";
export const b: Strict<"a" | "b", "c"> = "b";
export const c: Flat<["x", 1]> = ["x", [1]];
export const d: number = "" as Flat<["x"]>;

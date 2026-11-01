// A spread of `any` makes the whole literal `any`, whatever else it holds.
declare const scope: any;
declare const rec: Record<string, unknown>;
declare const flag: boolean;

const data = flag ? { ...rec, ...scope } : rec;
const value = data["k"];
export const sibling = typeof value === "boolean" ? undefined : value.when;

const after = { ...scope, z: 1 };
export const a: string = after.nothing;
const before = { a: 1, ...scope };
export const b: number = before.b;

export function generic<T>(x: T) {
  return { ...scope, ...x };
}
export const c: string = generic(1);

const plain = { ...rec, a: 1 };
export const d: string = plain.a;

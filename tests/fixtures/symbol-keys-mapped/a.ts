declare const r: Required<Set<string>>;
export const a: Set<string> = r;
export const b: Iterable<string> = r;
export const c: number = r[Symbol.iterator];
export const d: number = r[Symbol.toStringTag];
type M<T> = { [K in keyof T]: T[K] };
declare const m: M<Set<string>>;
export const g: Set<string> = m;
const s1 = Symbol();
declare const s2: unique symbol;
interface U { [s1]: number; [s2]: string; x: boolean; }
declare const mu: M<U>;
export const j: U = mu;
export const l: boolean = mu[s1];
export const l2: boolean = mu[s2];

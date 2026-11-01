export const o1 = { get z() { return o1.z; } };
export const o2 = { get z() { return 1; }, y: () => o2 };
export const o3 = { u: () => o3.u() };
export const o4 = { x() { return o4.y(); }, y() { return o4.x(); } };
export function id<T>(x: T) { return x; }
export const c2 = id(() => 1 as any as typeof c2);
export const c3 = id(function () { return c3; });
export function run(f: () => unknown) { return f; }
export const c4 = run(() => c4);
export function run2(f: () => void) { return f; }
export const c5 = run2(() => c5);
export function run3<T>(f: () => T) { return f; }
export const c6 = run3(() => c6);
export function run4(f: (x: number) => void) { return f; }
export const c7 = run4((x) => c7);
export function run7(f: (() => number) | string) { return f; }
export const c10 = run7(() => c10);
export const o5 = { get z() { return o5; } };
export function run8<T>(x: T, f: () => T) { return f; }
export const c12 = run8(1, () => c12);
export function run9<T>(f: () => number, x: T) { return f; }
export const c13 = run9(() => c13, 1);
export function run10<T extends () => unknown>(f: T) { return f; }
export const c14 = run10(() => c14);
export function run11<T>(f: (x: T) => number, x: T) { return f; }
export const c15 = run11((a) => c15, 1);
export const c16 = new Promise((res) => res(c16));
export const c17 = [1].forEach(() => c17);
export const c18 = [() => c18];
export const c19 = Promise.resolve(() => c19);
export declare function node(): { a: number };
export const asserted = node() as { a: number; b: string };
export const parens = (node()) as { a: 1 };
export const nonNull = node()!;
asserted.b;
parens.a;
nonNull.a;

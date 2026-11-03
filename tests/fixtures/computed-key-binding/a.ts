declare const k: string;
declare const n: number;
declare const flag: boolean;
const o: { a: number } = { a: 1 };
const { [k]: v } = o;
const { [n]: u } = o;
const { [flag]: b } = o;
export { v, u, b };

declare const r: Record<string, number>;
const { [k]: w } = r;
export const fixed: number = w;
const { [n]: x } = { 0: 'a' };
export { x };

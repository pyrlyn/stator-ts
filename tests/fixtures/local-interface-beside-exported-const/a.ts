interface Real<T = any> { x: T }
export declare const Real: { new (): Real };
export const a: Real = null!;
export type Alias = Real<string>;
const r: Real<number> = new Real();
const n: number = r.x;
function f(): Real { return new Real(); }
export { f };

export const After = 1;
interface After { b: string }
const after: After = { b: "x" };
export function afterValue() { return After + 1; }

// `invoke(fn, ...args)`: the lambda's parameters come from the arguments written after it.
declare function invoke<A extends unknown[], R>(fn: (page: string, ...args: A) => R, ...args: A): R;
declare const sel: string;
const button: 'left' | 'right' = 'left';
export const n: number = invoke((page, s, btn) => s.length + btn.length, sel, button);

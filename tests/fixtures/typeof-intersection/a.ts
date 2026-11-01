export enum P { a = 'a', b = 'b' }
type I = { readonly editor: P; readonly diff: P; readonly merge: P };
type C = Omit<I, 'merge'> & { readonly merge?: P };
export function f(p: P | C): I {
  if (typeof p !== 'string') {
    return { editor: p.editor, diff: p.diff, merge: p.merge ?? p.editor };
  }
  return { editor: p, diff: p, merge: p };
}
type Branded = string & { brand: 1 };
export function g(x: Branded | { n: number }, y: number): number {
  if (typeof x === 'string') {
    const n: number = x;
    return n;
  }
  const s: string = x;
  return s.length + x.n + y;
}
type Fn = (() => void) & { tag: string };
export function h(x: Fn | { n: number }): number {
  if (typeof x === 'function') {
    x();
    return x.tag.length;
  }
  return x.n;
}

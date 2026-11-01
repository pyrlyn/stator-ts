function f<A extends string>(p0: { [key in A]: {} | undefined }, p1: A) {
  const v: {} = p0[p1]!;
}
function g<T>(x: T) {
  const a: {} = x!;
  const b: {} = x;
  const c: T = x!;
}
function h<T extends string | undefined>(x: T) {
  const a: string = x!;
  const b: string = x;
}
function j<T extends { a: number } | null>(x: T) {
  return x?.a;
}
const r: string = j({ a: 1 });

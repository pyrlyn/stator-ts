type U =
  | { type: "a"; n: number }
  | { type: "b"; n?: undefined; diff: string }
  | { type: "c"; n: null; diff: string };
export function h(x: U) {
  return x.n ?? x.diff;
}
export function i(x: U) {
  return x.n || x.diff;
}
export function j(a: string | null, b: any) {
  const p = a ?? a;
  const q = b ?? b;
  return [p, q];
}
export function k(a: string) {
  return a ?? a.length;
}

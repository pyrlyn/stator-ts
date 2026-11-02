const arr = [[1], [2]];
const [x, [y]] = arr;
x.nothing;
y.nothing;
const [p = [0], [q = 1] = []] = arr;
p.nothing;
q.nothing;
const objs = [{ a: 1 }];
const [{ a }] = objs;
a.nothing;
function f([u, [v]]: number[][]) {
  u.nothing;
  v.nothing;
}
function g([u, [v], w = 1, , ...r]) {
  u.nothing;
  v.nothing;
  w.nothing;
  r.nothing;
}
g(1);
g([1]);
g([1, [2]]);
g([1, [2], 3, 4, 5]);
g([1, 2]);
function h([a]) {}
h([]);
h([1, 2]);
declare const maybe: number[] | undefined;
const [m] = maybe;
declare const maybeObj: { a: number } | undefined;
const { a: b } = maybeObj;
function j([k]: number[] | undefined = [1], { l }: { l: number } | undefined = { l: 1 }) {
  k.nothing;
  l.nothing;
}

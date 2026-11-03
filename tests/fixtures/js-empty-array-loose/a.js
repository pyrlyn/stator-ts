const a = [];
a.push(1);

const b = [];
const c = b.concat("x");
c[0].anything();

const s = new Set();
for (const v of s) v.toFixed(2);

function f(x) {
  return x;
}
f(1).toFixed(2);

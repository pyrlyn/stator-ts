const s = new Set();
s.add(1);
for (const v of s) v.toFixed(2);

function id(x) {
  return x;
}
function first(items = []) {
  return items[0];
}
first().toFixed(2);
const p = new Promise((resolve) => resolve(1));
p.then((v) => v.toFixed(2));
id(1);

const more = /** @type {string[]} */ ([]);
more.push(1);
more[0].nothing;
const n = /** @type {number} */ (/** @type {unknown} */ ('x'));
n.nothing;
const bad = /** @type {string} */ (1);
bad.nothing;
const o = /** @type {{ a: number }} */ ({ a: 1, b: 2 });
o.b;
const plain = /* @type {string} */ (1);
plain.nothing;
function f(x) {
  const y = /** @type {boolean} */ (x);
  y.nothing;
  return /** @type {number[]} */ (x).length;
}
f(1).nothing;
/** @type {any} */ (globalThis).extra = 1;

/**
 * @callback Describe
 * @param {number} n
 * @returns {string}
 */
function notDescribed(n) {
  return n;
}

/** @type {Describe} */
const described = (n) => String(n);

class Keys {
  /** @readonly */
  static key = Symbol();
}
Keys.key = Symbol();

export { notDescribed, described };

class Box {
  /** @type {number} */
  value = 0;
  /** @param {string} s */
  method(s) {
    return s.length;
  }
  /** @returns {number} */
  get size() {
    return this.value;
  }
}

/** @type {{ x?: number, y?: number }} */
const point = { x: 1 };
const missingY = point.y;
point.z = 1;

/** @type {string} */
const wrong = 1;

/**
 * Adds.
 * @param {number} a the first
 * @param {number} b
 * @returns {number}
 */
function add(a, b) {
  return a + b;
}
add(1, 'two');
add(1);

/** @param {number=} first @param {number} [second] */
function opt(first, second) {
  return first + second;
}
opt();

/** @type {?string} */
const nullable = null;
nullable.length;

/** @type {*} */
const anything = 1;
anything.whatever;

/** @type {{
 *   a: number,
 *   b: string,
 * }} */
const multi = { a: 1, b: 'b' };
multi.a.toFixed();
multi.c;

/**
 * @param {{x: number}} o
 * @returns {string}
 */
function pattern({ x }) {
  return x;
}

/** @param {...number} rest */
function spread(...rest) {
  return rest.length;
}
spread(1, 'a');

/** @param {number} a */
const arrow = (a) => a.length;

const holder = {
  /** @param {string} s */
  run(s) {
    return s.foo;
  },
  /** @returns {string} */
  other: function () {
    return 1;
  },
};

/** @param {Box | null} box */
function useBox(box) {
  return box.value;
}

// A plain comment between keeps the doc attached.
/** @returns {number} */
// here
function between() {
  return 'x';
}

/** not a tag: x@y.z */
export const plain = 1;

/** @type {number} */
export const exported = 'x';

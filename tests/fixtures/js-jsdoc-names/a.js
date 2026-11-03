/** @typedef {{ id: number }} Item */

/**
 * @callback Mapper
 * @param {Item} item
 * @returns {string}
 */

/** @type {Item} */
const item = { id: 1 };

/** @type {Mapper} */
const map = (i) => String(i.id);

/**
 * @template T
 * @param {T} v
 * @returns {T}
 */
function same(v) {
  return v;
}

/** @type {T} */
const outside = same(item);

export { map, outside };

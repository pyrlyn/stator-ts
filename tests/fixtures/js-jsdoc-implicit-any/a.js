/** @type {Array} */
const list = [1, 'two'];
list.push({});
list.nope;

/** @type {Promise} */
const later = Promise.resolve(1);
later.then((v) => v.anything);

/** @type {Object} */
const bag = {};
bag.anything;

/** @type {Map} */
const table = new Map();
table.set(1, 'one');

/** @type {String} */
const text = 1;

/** @type {Function} */
const fn = () => 1;
fn.nope;

// Without a tag the same escapes are errors.
const a = `\xZZ`;
const b = `head \u00G0 ${1} tail`;
const c = `head ${2} \x tail`;
const d = "\xZZ";
const e = `\u{110000}`;
export { a, b, c, d, e };

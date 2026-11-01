// Invalid escapes are legal in tagged templates: the cooked value is undefined, the raw one survives.
const path = String.raw`C:\users\me`;

function tag<T>(strings: TemplateStringsArray, ...values: T[]): string {
  return strings.raw.join("") + values.length;
}

const a = tag`\xZZ and \u00G0 and \u{110000} and \u{FFFFFFFFF}`;
const b = tag`head \x${1} middle \u${2} tail \u{`;
const c = tag<number>`\xq${3}\uq`;
const d = String.raw`\u{} ${a}${b}${c}`;
export { path, d };

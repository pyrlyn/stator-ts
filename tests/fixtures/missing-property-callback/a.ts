declare const o: { a: number };
o.foo((x) => x);
missing((y) => y);
const r = o.bar.baz((z) => z);
const n: string = r;

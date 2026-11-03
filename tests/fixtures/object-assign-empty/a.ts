const o = { a: 1 };
const r = Object.assign(o, {});
const n: string = r.a;
const s = Object.assign({}, o, { b: "" });
const m: number = s.b;

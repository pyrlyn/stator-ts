declare let u: "a" | "b" | number;
declare let v: string | number;

// `+=` keeps what `v` was, widened, not the type of what it adds.
v = "x";
v += 1;
const s: string = v;
const n: number = v;

// `u++` on a union keeps the literals' base types.
u = "a";
u++;
const w: "a" = u;

let k = 0;
k += 1;
const lit: 0 = k;

export { s, n, w, lit };

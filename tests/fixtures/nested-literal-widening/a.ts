// Sibling literals name each other's properties at every depth, not just at the top.
for (const { treatments } of [{ treatments: {} }, { treatments: { "a.b": true } }, { treatments: { "a.b": false, c: "x" } }]) {
  if (treatments["a.b"] !== undefined) {
    const v: boolean = treatments["a.b"];
  }
  const missing: number = treatments["a.b"];
}

const nested = [{ o: { p: {} } }, { o: { p: { q: 1 } } }, { o: {} }];
export const q = nested[0].o.p?.q;

declare const flag: boolean;
const either = flag ? { t: {} } : { t: { x: 1 } };
export const x: number | undefined = either.t.x;

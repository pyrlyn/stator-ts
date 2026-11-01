// `?.` removes null from `this`, so `flat` does not see the undefined side.
declare const p2: { kind?: number }[][] | undefined;
const a2 = p2?.flat() || [];
for (const c of a2) { c.kind; }
declare const p3: ({ kind?: number }[] | undefined)[] | undefined;
const a3 = p3?.flat() || [];
for (const c of a3) { c.kind; }

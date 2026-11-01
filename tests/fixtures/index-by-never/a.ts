declare const c: { v?: Readonly<{}> };
declare const k: string;
if (c.v?.[k as keyof typeof c.v]) {}
declare const o: { a: number };
const n: string = o[k as never];

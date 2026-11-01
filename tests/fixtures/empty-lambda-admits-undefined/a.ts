// The rule of TypeScript 6 and later. tsc 5.9, the default of tests/differential.sh, still reports
// the lambdas: run with TSC set to a newer tsc to compare.
export const f: () => string | undefined = () => {};
export const f2: (() => string | undefined) | undefined = () => {};
declare class P { constructor(a: ((x: number) => string[] | undefined) | undefined); }
export const p = new P(() => { });
export const q: () => Promise<string | undefined> = async () => {};
function plain() {}
export const g: () => string | undefined = plain;

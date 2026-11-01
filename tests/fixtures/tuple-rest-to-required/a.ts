declare const a: [number, ...string[]];
const b: [number, string, ...string[]] = a;
declare const c: string[];
const d: [...string[]] = c;
declare const e: [...string[]];
const g: [string, ...string[]] = e;
export {};

declare function h<T extends unknown[]>(tag: string, kids: [...T]): T;
declare const a: number;
declare const c: boolean;
const r = h('div', [a, 's', ...(c ? [true] : [])]);
const x: string = r;
declare const u: [number] | [number, string];
const v = h('p', u);
const w: boolean = v;

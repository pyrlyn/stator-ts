interface RA { readonly m: string; tag: 'a' }
interface A { readonly m: string | null; tag: 'a'; isR(): this is RA; u(): void }
interface RB { readonly m: string; tag: 'b' }
interface B { readonly m: string | null; tag: 'b'; isR(): this is RB; u(): void }
declare function getM(): A | B | undefined;
let t = getM();
if (t?.isR()) { const s: string = t.m; }
declare const tt: A | B;
if (tt.isR()) { const s: string = tt.m; const n: number = tt; }
interface CMD { endLine: number | undefined; x?: string }
declare function de(s: CMD & Required<Pick<CMD, 'endLine'>>): void;
declare const e: CMD;
de(e);
const rr: Required<CMD>['endLine'] = undefined;
const rr2: Required<CMD>['x'] = undefined;
declare const items: (string | number)[];
const vm = items.find(x => x);
if (!vm) throw new Error();
const node = (el: boolean | typeof vm) => ({ el });
const nn: { el: boolean | string | number } = node(vm);

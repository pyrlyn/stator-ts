// `e => isP(e)` is a guard when its false side leaves nothing of what the true side proved.
interface Art { readonly link?: string; kind: number }
declare function isP(a: Art, t: number): a is Art & { readonly link: string };
declare const entries: readonly Art[];
declare function key(s: string): string;
export const links = entries.filter(e => isP(e, 1)).map(e => key(e.link));
const guard: (e: Art) => e is Art & { readonly link: string } = e => isP(e, 1);
export { guard };

declare function isS(x: string | number): x is string;
declare const str: string;
if (!isS(str)) { str.length; }

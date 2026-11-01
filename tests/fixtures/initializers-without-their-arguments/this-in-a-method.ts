interface P { nav(e: number): string; comp(e: number[]): string; }
interface O { provider?: P; }
declare function mk<A extends any[]>(c: new (...a: A) => void, ...a: A): void;
declare function mk2<T>(t: T, o: O): T;
declare function mk3<A extends any[]>(c: (...a: A) => void, ...a: A): void;
class K { constructor(o: O) { } }
class KG<T> { constructor(o: O) { } }
declare function fO(o: O): void;
mk(K, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
mk(KG<number>, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
mk2(1, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
mk3(fO, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
export const a2 = mk(K, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
export const a3 = mk(KG<number>, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });
export const a4 = mk3(fO, { provider: { comp(els: number[]) { return els.map(e => this.nav(e)).join('/'); }, nav(e: number) { return 'x'; } } });

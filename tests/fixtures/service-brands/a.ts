declare const brand: unique symbol;
export interface BrandedService { _serviceBrand: undefined; }
export type GetLeadingNonServiceArgs<TArgs extends any[]> =
	TArgs extends [] ? []
	: TArgs extends [...infer TFirst, BrandedService] ? GetLeadingNonServiceArgs<TFirst>
	: TArgs;
export interface IInst {
	createInstance<Ctor extends new (...args: any[]) => unknown, R extends InstanceType<Ctor>>(ctor: Ctor, ...args: GetLeadingNonServiceArgs<ConstructorParameters<Ctor>>): R;
}
export interface Opt { readonly toolbar?: { primaryGroup?: string | ((g: string) => boolean) }; }
interface ISvc extends BrandedService { foo(): void; }
export class Tool { constructor(public a: string, public o: Opt, svc: ISvc) { } m() { return 1; } }
export function run(i: IInst) {
	const t = i.createInstance(Tool, 'a', { toolbar: { primaryGroup: g => g.startsWith('x') } });
	return t.m();
}
export interface Mock { stub<T>(service: Id<T>, ctor: Function): void; stub<T>(service: Id<T>, obj: Partial<T>): void; stub<V>(service: Id<any>, prop: string, value: V): void; }
export interface Id<T> { (...args: any[]): void; type: T; }
interface IChat { notify(e: string): void; other(n: number): string; }
export function st(m: Mock, id: Id<IChat>) {
	m.stub(id, { notify: e => e.length });
}
function rec(this: { a(x: string, y: number): void }) { }
rec.call({ a: async (u, v) => { u.length; v.toFixed(); } });
export type FF = typeof fetch;
export function cs(f: FF) { return f; }
cs(async (input, init) => { return new Response(String(input) + init?.method); });
export interface HD { showHover(options: string, focus?: boolean): number | undefined; }
export function q(x: { hoverDelegate: HD }) { return x; }
q({ hoverDelegate: { showHover(options, focus) { return options.length + (focus ? 1 : 0); } } });
export function ch(p: { n: string; t: number; f?: (x: string) => boolean; g?: { h: string } } | undefined, s: string | undefined, o: string, q?: { a: number } | null) {
	if (p?.n.toLowerCase() === o.toLowerCase() && 1 - p.t < 0) { return 1; }
	const a = typeof s?.length === 'number' ? s.length : 0;
	const b = s?.includes('a') && s.includes('b');
	const c = p?.n.startsWith(p.n);
	const d = [1].map(x => p?.g?.h + String(x + (p?.t ?? 0)));
	if (q?.a === 1) { q.a; }
	if (typeof p?.g?.h === 'string') { p.g.h; }
	const e = p?.f?.(p.n);
	return [a, b, c, d, e];
}
export function tr(): number {
	let r: number;
	try { r = 1; } catch (e) { throw e; } finally { console.log('x'); }
	return r;
}
export function tr2(): string {
	let s: string | undefined;
	try { s = 'a'; } finally { if (s === undefined) { s = 'b'; } }
	return s;
}
export function tr3(g: () => number): number {
	let v: number;
	try { v = g(); } catch { return 0; }
	try { console.log(v); } finally { console.log(v); }
	return v;
}
export function tr4(g: () => number): number {
	try { return g(); } finally { console.log(1); }
}
export function tr5(): void {
	let x: string | undefined = undefined as string | undefined;
	try { x = 'a'; throw new Error(); } catch { const y: string | undefined = x; console.log(y); }
}

// array literal against a tuple inside an intersection
interface J { oneOf?: J[]; kind?: 'a' | 'b' | ('a' | 'b')[]; n?: string; props?: { [k: string]: J } }
type W = J & { snip: string[] };
type C = J & { props: { [n: string]: { oneOf: [W, J] } } };
declare const cs: C;
declare const w: W;
declare const k: string;
cs.props[k] = { oneOf: [w, { kind: 'a', n: 'x' }] };

// no candidates: the default, not the return context
type Mock<T, E = never> = { [K in keyof T]: K extends E ? T[K] : number };
const mockObj = <T extends object>() => <TP extends Partial<T> = {}>(properties?: TP): Mock<T, keyof TP> => null!;
interface Shape { a(): void; b(): void }
let proxy: Mock<Shape>;
proxy = mockObj<Shape>()();
const prox2: Mock<Shape> = mockObj<Shape>()();

// conditional over any
type Dto<T> = T extends { toJSON(): infer U } ? U : T extends Function ? never : T extends object ? { [k in keyof T]: Dto<T[k]> } : T;
type Cached<T> = T & { id?: number };
interface Sym { name: string; loc: { uri: string } }
type SD = Cached<Dto<Sym>>;
function rev(d: SD | SD[] | undefined): Sym | Sym[] | undefined {
	if (!d) { return d; }
	return undefined;
}
declare const da: Dto<any>;
const da1: number = da;

// return context through Readonly over an intersection with a union
enum Src { U, E, F }
type Rule = { readonly e: string; readonly p: number } & ({ readonly s: Src.U; readonly x: string } | { readonly s: Src.E; readonly y: string } | { readonly s: Src.F });
declare const rules: Rule[];
rules.unshift(Object.freeze({ e: 'a', p: 1, s: Src.F }));

declare const dict: { [k: string]: number };
const keep1 = Object.freeze({ a: Src.E, b: 'x' as const });
const keep2: number = keep1;

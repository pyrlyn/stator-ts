// A string enum member and the string it holds are one value, and `(A | B) & Base` keeps the
// discriminant of each branch.
enum K { A = 'a', B = 'b' }
const enum N { One, Two }
type U = { kind: K.A; x: number } | { kind: K.B; y: number };
type V = { kind: N.One } | { kind: N.Two; y: number };
declare const u: U;
declare const v: V;

const a1 = u.kind === K.A ? u.x : u.y;
const a2 = u.kind === 'a' ? u.x : u.y;
const a3 = u.kind === 'b' ? undefined : u.x;
const a4 = v.kind === N.Two && v.y;
const a5 = u.kind !== 'a' ? u.y : u.x;
const a6 = u.kind === 'c' ? 1 : 2;

enum C { Markup = 1, Code = 2 }
interface Base { kind: C; shared: string }
class Code { readonly kind = C.Code; code = 1; }
class Markup { readonly kind = C.Markup; mark() { } }
type Cell = (Code | Markup) & Base;
declare const cells: Cell[];
cells.forEach(cell => {
	if (cell.kind === C.Markup) { cell.mark(); }
	else { cell.code; }
	cell.mark();
	const k: string = cell.kind;
});

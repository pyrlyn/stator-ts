// A guard for a type with optional members keeps only the union members that declare them.
interface Base { label: string }
interface WithRes extends Base { resource?: { path: string } }
interface A extends Base { symbolName: string }
interface B extends WithRes { editor?: string }
type U = A | B;
declare function hasRes(o: unknown): o is WithRes;
declare const pick: U;
if (hasRes(pick) && pick.resource) {
	pick.resource.path;
}

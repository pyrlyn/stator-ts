export function letOverParam(a: number) {
	let a = 1;
	return a;
}
export function constOverParam(b: number) {
	const b = 1;
	return b;
}
export function classOverParam(c: number) {
	class c {}
	return c;
}
export function bodyVarInInit(x = y) {
	var y = 1;
	return x + y;
}
export function bodyVarInInit2(x = () => z) {
	var z = 1;
	return x() + z;
}
export function varOtherType(a: number) {
	var a: string;
	return a;
}
export function varSameType(a: number) {
	var a: number;
	return a;
}
export function varNoAnnot(a: number) {
	var a;
	return a;
}
export function varInit(a: number) {
	var a = "s";
	return a;
}

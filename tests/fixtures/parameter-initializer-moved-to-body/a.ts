export function f(a = (() => b?.c)()) {
	var b: { c: number } | undefined;
	return [a, b];
}
export function g(a = (() => d ?? 1)()) {
	var d: number | undefined;
	return [a, d];
}
export function h(a = e) {
	var e = 1;
	return [a, e];
}
export function i(a = (() => k?.c)()) {
	var k: { c: number } | undefined;
	return [a, k];
}

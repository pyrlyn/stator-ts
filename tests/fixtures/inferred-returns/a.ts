export function onlyThrows() {
	throw new Error("x");
}
export const r1: never = onlyThrows();
export const fe = function () {
	throw new Error("x");
};
export const r2: never = fe();
export const ar = () => {
	throw new Error("x");
};
export const r3: never = ar();
export class C {
	m() {
		throw new Error("x");
	}
}
export const r4: never = new C().m();
export function self() {
	return self();
}
export function self2(n: number) {
	return n > 0 ? self2(n - 1) : 0;
}
export function mutualA() {
	return mutualB();
}
export function mutualB() {
	return mutualA();
}
export const v = () => v();
export function self3() {
	return [self3()];
}
export function self4() {
	return { x: self4() };
}
export function self5() {
	const r = self5();
	return r;
}

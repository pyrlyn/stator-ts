export function num() {
	return 1;
}

export const str = () => "s";

export function both(x: boolean) {
	if (x) return 1;
	return "s";
}

export function rec(n: number): number {
	return n > 0 ? rec(n - 1) : 0;
}

export const thrower = () => {
	throw new Error("no");
};

export const isString = (x: unknown) => typeof x === "string";

export class Inferred {
	x;
	y;
	constructor() {
		this.x = 1;
		this.y = "s";
	}
}

export function* gen() {
	yield 1;
	return "s";
}

export async function promised() {
	return 1;
}

export const later = (function () {
	return 1;
})();

export function reported(): string {
	return 1;
}

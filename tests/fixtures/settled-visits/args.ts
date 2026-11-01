export {};

declare function pick<T>(a: T, b: T): T;
declare function take(n: number): void;
declare function over(a: string): string;
declare function over(a: number): number;
declare function run<T>(f: () => T): T;
declare function each<T>(list: T[], f: (x: T) => void): void;

// An error a quiet pass held back still has to reach the visit in the open.
const inNested = pick(over(true), 1);
take(pick(1, over(false)));

// Nor does a call that settled on its signature keep the error from its own visit in the open.
declare function plain(n: number): number;
const inFixed = pick(plain("no"), 1);

// A lambda's body is checked though the pass that chose the signature already went over it.
const inLambda = pick(() => {
	const s: string = 1;
	return s;
}, () => "b");
run(() => {
	take("no");
});
each([1], x => {
	const s: string = x;
});

// So is a lambda in an argument of a call nested in another lambda.
run(() => run(() => {
	const n: number = "no";
	return n;
}));

// A call that fails goes back over its arguments in the open, and finds their lambdas again.
declare function once(f: () => void): number;
declare function twice(a: number, b: number): void;
twice(once(() => {
	const s: string = 1;
}), "no");
twice((() => {
	const s: string = 2;
}).length, "no");

// A statement call read for its flow effects first, its own turn second.
declare function assertNumber(x: unknown): asserts x is number;
declare function assertOver(x: unknown): asserts x is string;
declare function assertOver(x: unknown, y: number): asserts x is number;
function flows(x: unknown, y: unknown) {
	assertNumber(x);
	x.toFixed();
	assertOver(y, 1);
	y.toFixed();
	assertOver(y, "no");
}

// Statement calls that have no signature to read for their effects.
class Base {
	constructor(public size: number) {}
}
class Derived extends Base {
	constructor() {
		super("no");
	}
}
export async function load() {
	import("./inits");
	await import("./missing");
}

// A reference typed by a parameter narrows by where it is read, so one answer does not fit both.
interface Box {
	size: number;
}
export function read<T extends Box | undefined>(box: T, other: Box | undefined) {
	const held = box;
	if (box) {
		box.size;
		held.size;
	}
	box.size;
	take(other.size);
}

// Read for the generic overload first, where it stays `T`, and for the plain one after it.
type Shape = { kind: "a"; a: number } | { kind: "b"; b: string };
declare function fit<U extends string>(x: U): U;
declare function fit(x: { kind: "a"; a: number }): number;
export function narrow<T extends Shape>(x: T) {
	if (x.kind === "a") {
		fit(x).toFixed();
	}
}

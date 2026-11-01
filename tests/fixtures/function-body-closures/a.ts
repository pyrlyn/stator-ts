// Narrowing in a closure asks whether anything assigns the binding, and from where.
let shared: string | undefined = "a";

function assigns() {
	shared = undefined;
}

function reads() {
	return shared.length;
}

if (shared) {
	const f = () => shared.length;
}

const untouched: string | undefined = "b";
if (untouched) {
	const f = () => untouched.length;
}

function stable(x: string | undefined) {
	if (!x) return;
	return () => x.length;
}

function unstable(x: string | undefined) {
	if (!x) return;
	const f = () => x.length;
	x = undefined;
	return f;
}

function outer() {
	let v: number | null = 1;
	function set() {
		v = null;
	}
	set();
	return () => v.toFixed();
}

function neverSet() {
	let u: string;
	return () => u.length;
}

function unassigned() {
	let u: string;
	return u.length;
}

export { assigns, reads, stable, unstable, outer, neverSet, unassigned };

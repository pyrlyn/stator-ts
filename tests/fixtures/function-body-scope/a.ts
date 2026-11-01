// What a body declares joins the scope of the parameters, whose symbols every checker shares.
function merged(a: string, b: number) {
	var a: string;
	var b: number;
	return a.length + b;
}

function hoisted(value: number) {
	function value() {}
	return value;
}

function twice() {
	let x = 1;
	let x = 2;
	return x;
}

function expando() {
	function inner() {}
	inner.count = 1;
	return inner.count.toFixed();
}

function onParameter(fn: () => void) {
	fn.count = 1;
}

function ownTypes() {
	type Local = string;
	interface Shape {
		a: Local;
	}
	class Maker {
		make(): Shape {
			return { a: 1 };
		}
	}
	enum Kind {
		A,
	}
	return { made: new Maker().make(), kind: Kind.A };
}

const right: string = ownTypes().made.a;
const wrong: number = ownTypes().made.a;

function defaulted(a = later) {
	var local = 1;
	return a + local;
}
const later = 1;

export { merged, hoisted, twice, expando, onParameter, right, wrong, defaulted };

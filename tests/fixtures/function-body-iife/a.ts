// Called on the spot, a function's flow is part of the code around it.
let v: string | number = 1;

(function () {
	v = "a";
})();

v.toFixed();

const returned = (() => {
	return 1;
})();
const wrong: string = returned;

function around(x: string | number) {
	(() => {
		if (typeof x === "string") return;
	})();
	return x.length;
}

function throws() {
	(function () {
		throw new Error("no");
	})();
	return 1;
}

const typed: number = (() => {
	if (returned > 1) return "s";
	return 1;
})();

(async () => {
	v = 1;
})();

export { around, throws, typed };

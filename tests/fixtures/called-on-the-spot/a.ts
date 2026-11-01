// A function called on the spot sees the narrowings around it. A plain one is also part of the
// flow itself, so what it assigns or returns shows after the call.
declare class M {
	resolve(): Promise<void>;
}
declare function get(): M | undefined;
declare function make(): M;

function asyncReadsOuterNarrowing() {
	let model: M | undefined;
	model = get();
	if (model) {
		(async () => {
			await model.resolve();
		})();
		const later = () => model.resolve();
	} else {
		model = make();
	}
}

function assignedInside() {
	let a: string | undefined;
	(() => {
		a = 'a';
	})();
	a.length;

	let b: string;
	(function () {
		b = 'b';
	})();
	b.length;
}

function notInPlace() {
	let a: string;
	(async () => {
		a = 'a';
	})();
	a.length;

	let b: string;
	(function* () {
		b = 'b';
	})();
	b.length;
}

function returnsLandAfterTheCall(flag: boolean) {
	let a: string | undefined;
	(() => {
		if (flag) {
			return;
		}
		a = 'a';
	})();
	a.length;
}

function argumentsComeFirst() {
	let a: string | undefined;
	((v: unknown) => {
		a.length;
	})((a = 'a'));
}

function neverComesBack() {
	(() => {
		throw new Error();
	})();
	const unreachable: number = 'a';
}

const declaredInside = (() => {
	let local: string | undefined;
	local = 'a';
	return () => local.length;
})();

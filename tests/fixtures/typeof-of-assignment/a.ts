// `typeof (x = y)` narrows `x`, like the plain `(x = y)` it wraps.
declare function read(): string | null;

function loop() {
	let chunk: string | null;
	const out: string[] = [];
	while (typeof (chunk = read()) === 'string') {
		out.push(chunk);
	}
	return out;
}

function branches(p: string | number, u: string | undefined) {
	let q: string | number;
	if (typeof (q = p) === 'number') return q.toFixed();
	let v: string | undefined;
	if ((v = u) === undefined) return 0;
	if ((v = u) !== undefined) return v.length;
	return q.length;
}

function comma(p: string | number) {
	let q: string | number = p;
	if (typeof (read(), q) === 'string') return q.length;
	return q.toFixed();
}

function viaSwitch(p: string | number) {
	let q: string | number;
	switch (typeof (q = p)) {
		case 'string': return q.length;
		default: return q.toFixed();
	}
}

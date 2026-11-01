export function swap(a: number | undefined, b: number | undefined) {
	let start = a, end = b;
	if (start !== undefined && end !== undefined) {
		if (end < start) {
			[start, end] = [end, start];
		}
		const r: { start: number; end: number } = { start, end };
		return r;
	}
	return undefined;
}

export function members(o: { x: string; y: number }) {
	let x: string | number | undefined;
	let y: string | number | undefined;
	({ x, y } = o);
	x.trim();
	y.toFixed();
	({ x, y: x } = o);
	x.toFixed();
}

export function fromArray(xs: string[]) {
	let a: string | number | undefined;
	[a] = xs;
	a.trim();
	[a] = [1, 'x'];
	a.toFixed();
	// A real error: the second element is a string.
	[, a] = [1, 'x'];
	a.toFixed();
}

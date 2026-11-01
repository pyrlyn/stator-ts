// `{ ...x }` is a new object, so a readonly index signature of `x` does not carry over.
export function copy(x: Readonly<Record<string, unknown>>) {
	const v = { ...x };
	v['a'] = 1;
	return v;
}

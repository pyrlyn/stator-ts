export function literals(source: unknown): 'a' | 'b' | undefined {
	switch (source) {
		case 'a':
		case 'b':
			return source;
		default:
			return undefined;
	}
}

export function kinds(v: unknown, o: object) {
	switch (v) {
		case 1:
			return v.toFixed();
		case o:
			return v.toString();
		case null:
			return v;
	}
	// Past the switch nothing is known about the value.
	const x: string = v;
	return x;
}

// The written target of a compound assignment takes the base of its narrowed literal.
declare function check(): boolean;
declare function eq(actual: number, expected: number): asserts actual is 0;

function flags() {
	let supported = true;
	supported &&= check();
	supported ||= check();
	return supported;
}

function counts() {
	let n = 0;
	eq(n, 0);
	n += 1;
	return n;
}

function text() {
	let s = 'a';
	s += 'b';
	return s;
}

function kept() {
	let v: 'a' | 'b' = 'a';
	v += 'b';
	return v;
}

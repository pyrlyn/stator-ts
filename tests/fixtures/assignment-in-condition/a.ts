// The tested reference is the target of an assignment nested in the condition.
function loop(re: RegExp, text: string) {
	let match: RegExpExecArray | null;
	while ((match = re.exec(text)) !== null) {
		match.index;
	}
}

declare function next(): string | undefined;

function logicalAssign(v: string | undefined) {
	if ((v ??= next()) !== undefined) {
		v.length;
	}
}

function commaOperand(v: string | undefined) {
	if ((next(), v) !== undefined) {
		v.length;
	}
}

class Box { size = 1; }

function instanceTest(v: Box | undefined, make: () => Box | string) {
	let x: Box | string | undefined = v;
	if ((x = make()) instanceof Box) {
		x.size;
	}
}

function inTest(make: () => { a: string } | { b: number }) {
	let x: { a: string } | { b: number };
	if ('a' in (x = make())) {
		x.a;
	}
}

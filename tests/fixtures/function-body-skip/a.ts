// Each body holds something a look at its tokens alone can misread.
export function regexes(x: boolean, y: string) {
	if (x) /'/.test(y);
	if (x) /}/.test(y);
	const a = /[/}'"`]/.test(y);
	return a ? 4 / 2 / 1 : "}";
}

export function* generator() {
	yield /}/;
	yield /{/;
}

export async function awaits() {
	await /{/;
	await /}/;
}

export function templates(n: number) {
	const nested = `a${`b${n}c${{ n }.n}`}d}`;
	const brace = `}${"}"}{`;
	return nested + brace;
}

export function comments() {
	// }
	/* } */
	return 1; // {
}

export function strings() {
	return "}" + '{' + `{`;
}

export function division(a: number, b: number) {
	let i = 0;
	i++ / 2;
	return (a) / b / 2 + [a][0] / b + a / b;
}

export const arrow = () => {
	return { a: { b: 1 } };
};

export class C {
	m() {
		return this;
	}
	get g() {
		return { h: 1 };
	}
	set g(v) {}
}

export const wrong: number = strings();

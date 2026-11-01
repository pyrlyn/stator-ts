declare function pair(): [string, string | null];
declare const cond: boolean;
declare function take(x: string): void;

let [text, meta] = cond ? pair() : ['', null];
take(text);
meta = meta || 'x';

const [a, b = 1] = ['x'];
take(a);
export const n: number = b;

const [[c], d] = [[1], 'x'];
export const c1: number = c;
take(d);

const [e, ...f] = ['x', 1, 2];
take(e);
export const f1: number[] = f;

export function param([g, h] = ['x', 1]) {
	take(g);
	return h;
}

export async function all(p: Promise<string>, q: Promise<number>) {
	const [r, s] = await Promise.all([p, q]);
	take(r);
	return s.toFixed();
}

// A real error: `p` is a number.
const [p, q] = [1, 'x'];
take(p);
export const q1 = q;

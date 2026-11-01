type Compare<T> = (a: T, b: T) => number;
export function qs<T>(nth: number, data: T[], compare: Compare<T>): T {
	const lower: T[] = [];
	if (nth < 1) { return qs(nth, lower, compare); }
	return lower[0];
}
export function qs2<T>(nth: number, data: T[], compare: Compare<T>): T {
	nth = Math.trunc(nth);
	const pivot = data[0];
	const lower: T[] = [];
	for (const value of data) { const val = compare(value, pivot); if (val < 0) { lower.push(value); } }
	if (nth < lower.length) { return qs2(nth, lower, compare); } else { return lower[0]; }
}
declare function join(...a: string[]): string;
declare function use(s: string): void;
if (process.env['A']) {
	process.env['B'] = process.env['B'] || join('a');
	use(process.env['B']);
}
process.env['C'] = process.env['C'] || join('a');
use(process.env['C']);
declare function ctx(o: Iterable<[string, any]>): void;
export const m0 = ctx([['a', true], ['b', 1]]);

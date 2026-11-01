interface S { create(r?: (s: string) => Promise<number>): void }
function mk(): S { return { create: (r = async s => s.length) => { const q: boolean = r; } }; }
function mk2(): S { return { create(r = async s => s.length) { } }; }
const k3: (a?: (s: string) => void) => void = (a = s => { const n: number = s; }) => {};
const k4 = (a = (s: string) => s) => a;
type SC = { code: number } | undefined;
function on(l: (e: SC) => void) {
	const ad = (e: { x: number } | void) => {
		if (typeof e === 'undefined') {
			l(e);
		} else {
			const n: number = e;
		}
	};
}
function on2(e: string | void, f: unknown, g: {} | undefined, h: number | undefined | void) {
	if (typeof e !== 'undefined') { const n: number = e; } else { const n: number = e; }
	if (typeof f === 'undefined') { const n: number = f; }
	if (typeof g === 'undefined') { const n: number = g; }
	if (typeof h === 'undefined') { const n: number = h; }
}

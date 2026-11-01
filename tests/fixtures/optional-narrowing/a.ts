export function g5(o: { h?: Record<string, string>; u?: string }) {
	if (o.h || o.u) {
		o.h["a"];
		for (const k in o.h) {
			const x = o.h[k];
			const y = o.h.foo;
			return x + y;
		}
	}
	return "";
}
export function g6(o: { h?: Record<string, string> }) {
	for (const k in o.h) {
		const x = o.h[k];
		return x;
	}
	return "";
}
export function g7(h?: Record<string, string>) {
	for (const k in h) {
		h[k];
	}
	for (const k of Object.keys(h!)) { h[k]; }
}

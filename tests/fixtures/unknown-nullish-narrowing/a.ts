declare const parsed: unknown;
if (parsed !== null && typeof parsed === 'object') {
	const k: object = parsed;
	Object.keys(parsed);
}
declare const v2: unknown;
if (typeof v2 === 'object' && v2 !== null) {
	const k: object = v2;
	Object.keys(v2);
	Object.entries(v2);
}
declare const v3: unknown;
if (typeof v3 === 'object' && !Array.isArray(v3)) {
	Object.keys(v3 ?? {});
}
function f(value: unknown) {
	if (!value || typeof value !== 'object') return;
	Object.keys(value);
}
function g(value: unknown) {
	if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
		Object.keys(value);
		Object.entries(value);
	}
}
function h(value: unknown): unknown {
	if (value !== null) { value; } 
	const k: unknown = value;
	return k;
}
function j(value: unknown) {
	if (value === null) return 1;
	const r: {} | undefined = value;
	if (value !== undefined) {
		const s: {} = value;
		return s;
	}
	return value;
}
function m(value: unknown) {
	if (value !== null) { } else { }
	// @ts-expect-error
	value.x;
	const q: string = value;
}

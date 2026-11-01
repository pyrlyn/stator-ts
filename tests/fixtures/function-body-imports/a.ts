// `b` and `c` are reachable only from inside bodies, and `meta` is a module only because of one.
async function load() {
	const b = await import("./b");
	const wrong: string = b.value;
	return wrong;
}

function inType() {
	let c: typeof import("./c") | undefined;
	return c?.named.toFixed();
}

const stub = { import(name: string) { return name; } };

function notAnImport() {
	return stub.import("./missing");
}

function missing() {
	return import("./not-there");
}

export { load, inType, notAnImport, missing };

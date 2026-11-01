export function f() {
	import c = require("./missing");
	import d = require("./b");
	return [c, d];
}
export class K {
	m() {
		import e = require("./missing2");
		return e;
	}
}

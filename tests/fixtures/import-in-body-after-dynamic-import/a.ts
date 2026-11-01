const p = import("./b");
function f() {
	import { v } from "./b";
	import x = require("./c");
	return [v, x];
}

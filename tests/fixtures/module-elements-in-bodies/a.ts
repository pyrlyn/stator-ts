export function f() {
	declare const a: number;
	export const b = 1;
	import { c } from "./b";
	import d = require("./b");
	export default 1;
	export { nothing };
	export * from "./b";
	import "./b";
	export function g() {}
	namespace N {}
	module M {}
	declare module "x" {}
	interface I {}
	type T = 1;
	enum E {}
	abstract class A {}
	declare function z(): void;
	export = 1;
	public const q = 1;
	async const r = 1;
	return [a, b, c, d];
}
{
	import { x } from "./b";
	export const y = 1;
	namespace N2 {}
	declare module "y" {}
	module M2 {}
}
if (true) {
	export const z = 1;
	import "./b";
}
export namespace NS {
	export function f() {
		import { y } from "./b";
		namespace Inner {}
		declare module "w" {}
	}
	import "./b";
	import * as n from "./b";
	export * from "./b";
	export default 1;
}

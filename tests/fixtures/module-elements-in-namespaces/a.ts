export {};
const local = 1;
namespace A { const inner = 1; export { inner }; }
namespace B { export = local; }
namespace C { export default local; }
namespace D.E { import x from "./b"; export * from "./b"; }
namespace F { import y = require("./b"); export const u = y; }
declare namespace G { export { local }; export = local; export default local; import z from "./b"; }
function a() {
	function inner() { declare var v; }
	async function ok() {}
	const enum Ce {}
	abstract class Ab {}
	export abstract class Ex {}
	export const enum Ec {}
	declare const enum Ed {}
	export async function ea() {}
	export interface I {}
	export type T = 1;
	export enum En {}
	export default function df() {}
	export default class Dc {}
	if (1) export function n() {}
	switch (1) { case 1: export const z = 1; declare function dd(): void; }
	for (;;) { export var w; break; }
	const arrow = () => { export const q = 1; import "./b"; };
	class K { m() { export const q2 = 1; import { v } from "./b"; return v; } }
}
function unused() { import { v as u1 } from "./b"; import * as u2 from "./b"; import u3 = require("./b"); import u4 from "./b"; }
function used() {
	import { v as a1, W as a2 } from "./b";
	import * as a3 from "./b";
	import a4 from "./b";
	import a5 = require("./nope");
	let t: a2 = 1;
	let t2: a3.W;
	return [a1, a3, a4, a5];
}

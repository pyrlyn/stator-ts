export {};
declare const anyBase: any;
declare const dyn: string;
const sym = Symbol();
abstract class B<T> {
	x = 1;
	private p = 1;
	protected q = 1;
	static s = 1;
	static m() {}
	m() {}
	abstract am(): void;
	abstract ap: number;
	get g() { return 1; }
	[sym]() {}
	value!: T;
}
abstract class D extends B<string> {
	x = 2;
	override y = 3;
	override mm() {}
	m() {}
	static s = 2;
	static override t = 2;
	static override m() {}
	static override length = 1;
	static name2 = 1;
	am() {}
	ap = 1;
	get g() { return 2; }
	[sym]() {}
	override [dyn]() {}
	declare q: number;
	#x = 1;
}
abstract class D2 extends B<number> {
	abstract am(): void;
	constructor(override x: number, public q: number) { super(); }
}
class N {
	override a = 1;
	override b() {}
	static override c = 1;
}
class A1 extends anyBase {
	override a = 1;
	b() {}
}
class A2 extends Missing {
	override a = 1;
	b() {}
}
class A3 extends (null as any as new () => Missing2) {
	override a = 1;
}
}
const e1 = class extends B<string> {
	override zz() {}
	x = 1;
	am() {}
	ap = 1;
};
new class {
	override a = 1;
};
class E2 extends Error {
	override message = 'x';
	name = 'y';
	override stack = '';
	override cause2 = 1;
}
class S1 extends B<string> {
	override mx() {}
	am() {}
	ap = 1;
	override valeu!: string;
}
declare class Amb extends B<string> {
	x: number;
	override y: number;
	am(): void;
	ap: number;
}
interface I { i: number }
class Impl implements I {
	override i = 1;
}

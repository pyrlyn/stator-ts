// The static side of a class has its own index signatures, and inherits through any base type.
class S {
	static [s: string]: number;
	x = 1;
}
const r1: string = S.a;
const inst = new S();
inst.b;

function make() {
	return class<T> {
		static [s: string]: number;
		static [s: number]: 42;
		foo(v: T) { return v; }
	};
}
const C = make();
C.a;
C.a = 1;
C[2];

declare var Base: any;
class FromAny extends Base {
	known = 1;
	static sknown = 2;
}
FromAny.sknown.length;
FromAny.sunknown.length;

declare class Core {
	static extend<Statics, Instance extends B1, T1, B1>(this: Statics & { new(): Instance }, arg1: T1): Readonly<Statics> & { new(): T1 & Instance };
	toString(): string;
}
declare class A extends Core.extend({}) { }
declare class B extends A.extend({}) { }
Core.missing;
A.missing;

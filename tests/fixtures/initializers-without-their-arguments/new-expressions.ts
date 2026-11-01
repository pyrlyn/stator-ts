declare function user(config: number): { a: number };
class C { count = 0; constructor(public read: () => { a: number }) { } }
class G<T> { count = 0; constructor(public read: () => T) { } }
class O { count = 0; constructor(read: () => { a: number }); constructor(read: string); constructor(read: any) { } }
class D extends C { }
class N { count = 0; constructor(read: () => { a: number }) { } static s = 1; }
declare const IF: { new(read: () => { a: number }): C };
declare const IP: { new(read: () => { a: number }): C; p: number };
declare const IC: { new(read: () => { a: number }): C; (): void };
declare const I2: { new(read: () => { a: number }): C; new(read: string): C };
declare const IG: { new <T>(read: () => { a: number }): C };
declare function nm(): typeof C;
export function f() {
	const n1 = new G<number>(() => n1.count);
	const n2 = new G(() => n2.count);
	const n3 = new O(() => ({ a: n3.count }));
	const n4 = (new C(() => ({ a: n4.count })));
	const n5 = new C(() => ({ a: n5.count })) as C;
	let n6 = new C(() => ({ a: n6.count }));
	var n7 = new C(() => ({ a: n7.count }));
	const n8 = new D(() => ({ a: n8.count }));
	const n9 = new N(() => ({ a: n9.count }));
	const n10 = new IF(() => ({ a: n10.count }));
	const n11 = new IP(() => ({ a: n11.count }));
	const n12 = new IC(() => ({ a: n12.count }));
	const n13 = new I2(() => ({ a: n13.count }));
	const n14 = new IG(() => ({ a: n14.count }));
	const n15 = new (nm())(() => ({ a: n15.count }));
	const n16 = new C(() => ({ a: 1 })).count + n16;
	const n17 = new n17();
	const n18 = new C(() => ({ a: n18.count, b: 1 }));
	const n19 = new C(1 as any, n19);
	const n20 = new G<typeof n20>(() => n20);
}
export class P { x = new C(() => ({ a: this.x.count })); y = new G(() => this.y.count); }
export function g(p = new C(() => ({ a: p.count }))) { }

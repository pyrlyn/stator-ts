// `f.x = 1` beside the declaration of `f` adds a member to the function.
interface Listener<E> { extension: string; (e: E): any; }

function make<E>(name: string) {
	const a: Listener<E> = function wrapped(e: E) { };
	a.extension = name;
	const b: Listener<E> = (e: E) => { };
	b.extension = name;
	let c: Listener<E> = function wrapped(e: E) { };
	c.extension = name;
	const d: Listener<E> = function wrapped(e: E) { };
	const e2: Listener<E> = function wrapped(e: E) { };
	e2.extension = 1;
	return [a, b, c, d];
}

function f() { }
f.x = 1;
f.y = 'a';
f.y = 2;
f.m = function (n: number) { return n; };
f.z = undefined;
f.w = null;
const r1: string = f.x;
const r2: boolean = f.y;
const r3: boolean = f.m;
const r4: boolean = f.z;
const r5: boolean = f.w;

g.early = 1;
function g() { }
const r6: boolean = g.early;

const h = () => { };
h.a = { b: 1 };
h.a.c = 2;
h['lit'] = 1;
h[`tmpl`] = 1;
h[7] = 1;
const r7: boolean = h.lit;
const r8: boolean = h.tmpl;
const r9: boolean = h[7];

function outer() {
	f.inner = 1;
	const i = function () { };
	if (i) { i.nested = 1; }
	{ const k = () => 0; k.q = 1; }
	return i.nested;
}

let notConst = function () { };
notConst.foo = 1;
var alsoNot = function () { };
alsoNot.foo = 1;
class K { }
K.p = 1;
const o = { fn() { } };
o.fn.x = 1;
const parens = (function () { });
parens.x = 1;

function self() { }
self.me = self;
self.q = self.q2;
self.q2 = 1;

const key = 'late';
const sym = Symbol();
function late() { }
late[key] = 1;
late[sym] = 'a';
const r10: boolean = late.late;
const r11: boolean = late[sym];

function merged() { }
merged.p1 = 1;
merged.p4 = 4;
merged.p8 = false;
namespace merged {
	export var p2 = 2;
	export var p4 = 4;
	export var p8 = 8;
}
const r12: boolean = merged.p1;
const r13: boolean = merged.p4;

function untyped() { }
untyped.m = function (n) { return n; };
export { };

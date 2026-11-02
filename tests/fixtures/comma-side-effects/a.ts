declare const o: { f(): void };
declare function g(): number;
let n = 0;
const a = (1, 2);
const b = (g(), 2);
const c = (n++, n);
const d = ("s", `t`, [1], {}, !n, -n, typeof n, n!, () => 1);
const e = (n ? 1 : 2, n ? g() : 2);
const f = (n + 1, n = 2);
(0, o.f)();
(0, eval)("1");
(1, o.f)();
const h = (void 0, 3);
const i = (class {}, function () {}, null, true, 1n, /x/);
for (let k = 0, j = 0; k < 1; k++, j++) {}

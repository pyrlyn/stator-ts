import assert from 'assert';
function f1(s: string | undefined, g: () => { o: string }) { const r = s && g(); return !!r && r.o; }
function f2(n: number, b: boolean, o: { a: 1 } | null) { const a = n && 'x'; const c = b && 'y'; const d = o && 1; const u: 0 | 'x' = a; const v: false | 'y' = c; const w: null | 1 = d; }
type U = { type: 'a'; description: string } | { type: 'b'; other: number };
declare const u: U | undefined;
function f3() { const child = u; assert.ok(child); assert.strictEqual(child.type, 'a'); child.description; }
function f4(m: { st?: { message: string } }) { assert.ok(!m.st); m.st!.message; }
class M { get st(): { message: string } | undefined { return undefined; } show(): void {} }
function f5(m: M) { assert.ok(!m.st); m.show(); m.st!.message; }
declare const r: { value: string; ok: true } | { error: string; ok: false };
function f6() { assert.strictEqual(r.ok, true); r.value; assert.deepStrictEqual(r, { value: 'a', ok: true }); }

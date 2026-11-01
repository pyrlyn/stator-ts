// A template span only ever holds a string, which is also what a failed match leaves there.
type Split<T> = T extends `${infer H}.${infer R}` ? [H, R] : 'none';
const a: Split<'a.b'> = ['a', 'b'];
const b: Split<'ab'> = 'none';
const c: Split<'ab'> = ['a', 'b'];
// Candidates in contravariant positions meet, they do not compete.
type Both<U> = (U extends any ? (k: U) => void : never) extends (k: infer I) => void ? I : never;
const d: Both<{ a: 1 } | { b: 2 }> = { a: 1, b: 2 };
const e: Both<{ a: 1 } | { b: 2 }> = { a: 1 };
// An empty tuple has no element, not an `undefined` one.
type Nothing = [][number];
const f: Nothing = undefined;
const g: Both<[][number]> = 1;
// What a rest position takes from a readonly tuple is a fresh, mutable tuple.
type Tail<T> = T extends readonly [unknown, ...infer R] ? R : never;
const h: Tail<readonly [1, 2, 3]> = [2, 3];
const i: Tail<readonly [1, 2, 3]> = [2];

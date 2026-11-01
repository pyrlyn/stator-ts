// A rest parameter whose constraint is primitive keeps the arguments as literals.
declare class Box<T> {
	value: T;
}
declare function oneOf<T extends string[]>(...values: T): Box<T[number]>;
declare function nums<T extends number[]>(...values: T): T;
declare function mixed<T extends (string | number)[]>(...values: T): T;
declare function open<T extends unknown[]>(...values: T): T;
declare function anyArgs<T extends any[]>(...values: T): T;
declare function after<T extends string[]>(first: number, ...values: T): T;

const a: Box<'x' | 'y'> = oneOf('x', 'y');
const b: [1, 2] = nums(1, 2);
const c: ['a', 1] = mixed('a', 1);
const d: [string, number] = open('a', 1);
const e: ['a', 1] = open('a', 1);
const f: [string] = anyArgs('a');
const g: ['a', 'b'] = after(0, 'a', 'b');

const bad: Box<'x'> = oneOf('x', 'y');

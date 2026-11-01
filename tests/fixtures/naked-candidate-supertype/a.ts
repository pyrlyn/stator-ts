declare function both<T>(a: T, b: T): T;
declare function list<T>(a: T[]): T;
declare function deep<T>(a: T & {}, b: T & {}): T;

const one = both({ a: 1 }, { a: 2, b: 3 });
const oneBad: string = one;
const two = both('a', 1);
const three = deep({ a: 1 }, { a: 2 });
const threeOk: { a: number } = three;
const four = deep({ a: 1 }, { b: 2 });
const five = list([1, 'a']);
const fiveBad: boolean = five;

// Return priority candidates are the only ones that get united.
declare function ret<T>(a: T | undefined): T;
const six: 'a' | 'b' = ret('a');

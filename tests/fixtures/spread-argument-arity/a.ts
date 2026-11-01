declare const xs: number[];
declare function one(a: number): void;
declare function two(a: number, b: number): void;
declare function rest(a: number, ...r: number[]): void;
one(1, ...xs);
two(...xs);
rest(1, ...xs);
rest(...xs);
export {};

export type Strict<T, U extends [U] extends [U extends unknown ? ([T] extends [U] ? never : U) : never] ? unknown : never> = Exclude<T, U>;
export type Paren<T> = T extends (T extends string ? 1 : 2) ? 'a' : 'b';
export type Member<T> = T extends { x: T extends string ? 1 : 2 } ? 'a' : 'b';
export type Index<T> = T extends string[][T extends string ? 0 : 1] ? 'a' : 'b';
export type Fn<T> = T extends [() => T extends string ? 1 : 2] ? 'a' : 'b';

// Bare, it stays an error: `extends` of an `extends` is what the rule is there for.
export type Bare<T> = T extends T extends string ? 1 : 2 ? 'a' : 'b';

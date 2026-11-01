// Overloads of two array instantiations never merge, so the union reads as one array of both.
interface Item {
  a: number;
  c?: boolean;
}

declare const tuples: readonly [] | readonly [Item];
export const every = tuples.every(y => y.c);
export const some = tuples.some(y => y.c);
export const filtered = tuples.filter(y => y.c);
export const found = tuples.find(y => y.c);
export const mapped = tuples.map(y => y.c);
tuples.forEach(y => y.c);

declare const arrays: Item[] | { a: number; b: string }[];
export const everyA = arrays.every(y => y.a);
export const filteredA = arrays.filter(y => y.a);
export const bad = arrays.every(y => y.nope);

declare const mixed: string[] | readonly number[];
export const m = mixed.every(y => y.toFixed());

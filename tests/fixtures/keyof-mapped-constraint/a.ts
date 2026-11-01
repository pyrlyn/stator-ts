// `keyof` of a mapped type is its constraint: a string index does not bring
// `number` along the way it does for a declared index signature.
const sample: Record<string, unknown> = {};
const keys = Object.keys(sample) as readonly (keyof typeof sample)[];
declare function takeString(s: string): string;
for (const k of keys) takeString(k);

type Pair = keyof { [P in 'a' | 'b']: 1 };
export const pair: Pair = 'a';
export const noPair: Pair = 'c';

type Part = keyof Partial<{ x: 1 }>;
export const part: Part = 'x';

interface Indexed { [k: string]: unknown }
declare const indexed: keyof Indexed;
takeString(indexed);

type Q<T> = T extends [infer F, ...infer Rest] ? [Rest, Q<Rest>] : 0;
declare const b: Q<['a', 'b']>;
export const a2: boolean = b;
type U<T> = T extends [infer F, ...infer Rest] ? F | U<Rest> : never;
export const a3: 'a' | 'b' | 'c' = 0 as unknown as U<['a', 'b', 'c']>;
export const a4: 'a' | 'b' = 0 as unknown as U<['a', 'b', 'c']>;
type Tr<T> = T extends `${infer H}.${infer R}` ? [H, ...Tr<R>] : [T];
export const a5: number = 0 as unknown as Tr<'a.b.c'>;

declare function pick(o: {}): string;
declare function pick(o: object): number;

const held = { x: 1 };

// A fresh literal is no subtype of `{}`, so the first overload waits for the assignable pass.
export const fresh: number = pick({ x: 1 });
export const stale: string = pick(held);
export const empty: string = pick({});
export const wrong: string = pick({ x: 1 });

export const keys: string[] = Object.keys({ a: 1 });

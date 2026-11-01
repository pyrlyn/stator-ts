interface X { id: string }
declare const t: readonly [] | readonly [X];
export const ids = t.map(a => a.id);
declare const u: string[] | number[];
export const v = u.map(a => a);
const bad: boolean[] = u.map(a => a);
export { bad };

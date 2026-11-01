declare const a: { w(): number }[];
export const x = a.reduce((r, t) => r + t.w(), 0);
export const y = a.reduce((r: number, t) => r + t.w(), 0);

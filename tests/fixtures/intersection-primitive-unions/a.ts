// Over 100,000 pairs, yet primitive unions intersect by membership and never reach the limit.
type D = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9;
type K = `${D}${D}${D}`;
type L = K | "z";
type M = K | "y" | 1;

declare const both: L & M;
export const kept: K = both;

export const ok: L & M = "123";
export const dropped: L & M = "z";
export const other: L & M = "y";

// A literal survives beside its own primitive.
declare const wide: ("a" | "b") & (string | number);
export const a: "a" | "b" = wide;
export const none: ("a" | "b") & (1 | 2) = "a";

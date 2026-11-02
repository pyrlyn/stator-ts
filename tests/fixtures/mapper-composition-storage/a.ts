type Record17<A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q> = {
    first: A;
    last: Q;
    all: [A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q];
};
type Deferred<A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q> =
    A extends string ? Record17<A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q> : never;
type Rebind<A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q> =
    Deferred<A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q>;

declare const first: Rebind<"first", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>;
declare const second: Rebind<"second", 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1>;
const firstEnd: 16 = first.last;
const secondEnd: 1 = second.last;
const wrongFirst: 1 = first.last;
const wrongSecond: 16 = second.last;
const values: ["first", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16] = first.all;

type Wrap<T> = { [K in keyof T]: { value: T[K] } };
declare const wrapped: Wrap<typeof values>;
const lastBox: 16 = wrapped[16].value;
const wrongBox: 15 = wrapped[16].value;

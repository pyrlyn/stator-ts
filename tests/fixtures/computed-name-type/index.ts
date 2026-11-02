declare const key: string;
declare const num: number;
declare const sym: unique symbol;
declare const flag: boolean;
declare const obj: { a: number };
declare const maybe: string | undefined;
declare const loose: any;

enum Keys { A = "a", B = "b" }

export const literal = {
    [key]: 1,
    [num]: 2,
    [sym]: 3,
    [Keys.A]: 4,
    [loose]: 5,
    [flag]: 6,
    [obj]: 7,
    [maybe]: 8,
    [null]: 9,
};

export class Members {
    [flag]() {}
    get [obj]() { return 1; }
}

export function generic<K extends string, V>(k: K, v: V) {
    return { [k]: 1, [v]: 2 };
}

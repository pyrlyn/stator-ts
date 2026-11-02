export function f(x: number = 1): void;
export function f(x: string = 2): void;
export function f(x: any = 3) {}

export class C {
    constructor(a: number = 1);
    constructor(a: any = 2) {}
    m(b = "x"): void;
    m(b?: string) {}
}

export interface I {
    (a: number = 1): void;
    new (b = 2): I;
    m(c = 3): void;
}

export interface J {
    [k: string = "s"]: number;
}

export type F = (a: number = 1) => void;
export type G = new (b = "") => object;
export declare function g(x = 1): void;
export const h = (x: number = 1) => x;

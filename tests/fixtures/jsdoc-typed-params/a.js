/**
 * @param {number} a
 * @param {string} b
 */
export function documented(a, b, undocumented) {
    return [a, b, undocumented];
}

/** @type {(x: number) => number} */
export const typed = x => x;

export class C {
    /** @param {number} n */
    method(n, m) {
        return n + m;
    }
}

export function plain(p) {
    return p;
}

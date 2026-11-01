interface H { deep?: { fn?: () => string } }
declare const h: H;
function chained() {
    if (h.deep?.fn) return 1;
    const x: number = h.deep!.fn;
    return x;
}
function plain() {
    if (h.deep?.fn) return 1;
    type T = typeof h.deep.fn;
    const x: T = 1;
    return x;
}
function plain2() {
    if (h.deep && h.deep.fn) return 1;
    type T = typeof h.deep.fn;
    const x: T = 1;
    return x;
}

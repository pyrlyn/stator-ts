export function g<T extends object>(s: T, on: boolean): T { return on ? { ...s } : s; }
export function h<T extends { a?: number }>(s: T, on: boolean): T { return on ? { ...s, a: 1 } : s; }
export function j<T extends object>(s: T) { const r = { b: 2, ...s, c: 1 }; return r.b + r.c; }
export function k<T extends object>(s: T) { const r = { ...s, c: 1 }; return r.d; }
export function l<T extends object>(s: T): string { return { ...s }; }

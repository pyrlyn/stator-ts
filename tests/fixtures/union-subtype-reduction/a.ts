declare const c: boolean;

declare const pn: Promise<number>;
declare const pv: Promise<void>;
declare const pu: Promise<unknown>;
declare const pa: Promise<any>;
export const p1: boolean = c ? pn : pu;
export const p2: boolean = c ? pv : pu;
export const p3: boolean = c ? pa : pu;
export const p4: boolean = c ? pn : c ? pv : pu;

class A { a = 1; }
class B { a = 1; }
export const classes: boolean = c ? new A() : new B();

declare const m: { [k: string]: string } | undefined;
export const key = (m ?? {})['label'];
export const fresh: boolean = m ?? {};

declare const v: string | string[];
const flat = Array.isArray(v) ? v : [v];
export const arr: boolean = flat;

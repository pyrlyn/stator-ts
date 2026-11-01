// `Readonly<Record<string, T>>` has its keys settled, so `T` is reached through the index signature.
declare function viaRecord<T>(record: Readonly<Record<string, T>>): { kept: Record<string, T> };
declare function viaLiteral<T>(record: Readonly<{ [k: string]: T }>): T;
declare function viaPartial<T>(record: Partial<Record<string, T>>): T;
declare function viaKnown<T>(record: Readonly<{ a: T }>): T;
declare function viaName<T>(record: { [K in 'a' as `x${K}`]: T }): T;
declare const r: Record<string, number>;

const a: Record<string, number> = viaRecord(r).kept;
const b: string = viaLiteral(r);
const c: string = viaPartial(r);
const d: string = viaKnown({ a: 1 });
const e: string = viaName({ xa: 1 });

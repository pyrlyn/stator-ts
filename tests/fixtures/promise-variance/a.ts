declare const pn: Promise<number>;
declare const pu: Promise<unknown>;

export const up: Promise<unknown> = pn;
export const down: Promise<number> = pu;

interface Box<T> {
  then(cb?: ((value: T) => void) | null): void;
}
declare const bn: Box<number>;
declare const bu: Box<unknown>;
export const a: Box<unknown> = bn;
export const b: Box<number> = bu;

interface Generic<T> {
  run<U>(cb?: ((value: T) => U) | undefined): U;
}
declare const gn: Generic<number>;
declare const gu: Generic<unknown>;
export const e: Generic<unknown> = gn;
export const f: Generic<number> = gu;

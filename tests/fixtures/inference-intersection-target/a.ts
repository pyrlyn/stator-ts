interface D { dispose(): void }
class X implements D { dispose() {} x = 1; }
class Y implements D { dispose() {} y = 1; }
declare function mk(): X | Y;
declare const c: boolean;

class Lazy<T = string> {
  constructor(f: () => Promise<T & D | null>) {}
}
export const lazy: boolean = new Lazy(async () => {
  if (c) return null;
  if (c) return mk();
  return new X();
});

declare function g<T>(f: Promise<T & D | null>): T;
declare const p: Promise<X | Y | null>;
export const r1: boolean = g(p);

declare function extra<T>(x: string[] & T): T;
declare const e: string[] & { extra: 1 };
export const r2: boolean = extra(e);

declare function two<T, U>(x: T & U): [T, U];
export const r3: boolean = two(1);

declare function lower<T>(a: T & D, b: T): T;
declare const z: X;
export const r4: boolean = lower(z, 1);

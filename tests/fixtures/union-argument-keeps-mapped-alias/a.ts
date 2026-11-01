interface Z3 { [k: string]: { _output: any; a: 1 } }
type Z4 = Readonly<{ [k: string]: { _output: any; b: 2 } }>;
type AnyZ = Z3 | Z4;
type InferShape<T extends AnyZ> = { [K in keyof T]: T[K] extends { _output: infer O } ? O : never };
declare function tool<S extends AnyZ>(s: S, h: (a: InferShape<S>, e: unknown) => void): S;
type ZQ = typeof tool extends (...args: infer P) => any ? P : 2;
const zq: "z" = null as any as ZQ;
declare function one<S extends Z3>(s: S, h: (a: InferShape<S>, e: unknown) => void): S;
type ZR = typeof one extends (...args: infer P) => any ? P : 2;
const zr: "z" = null as any as ZR;
type Sh2<T extends AnyZ> = { [K in keyof T]: T[K] extends { _output: infer O } ? O : never } & {};
declare function two<S extends AnyZ>(s: S, h: (a: Sh2<S>, e: unknown) => void, x?: { y?: boolean }): S;
type ZS = Parameters<typeof two>[2];
const zs: "z" = null as any as ZS;
declare const a2: Sh2<AnyZ>;
const a3: "z" = a2;

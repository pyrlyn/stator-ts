type V = string | number;
declare function Enum<Values extends V[]>(values: readonly [...Values]): Values;
declare function Mid<Values extends V[]>(values: [boolean, ...Values]): Values;
declare function Open<Values extends unknown[]>(values: [...Values]): Values;

const a: 'ts' | 'js' = Enum(['ts', 'js'])[0];
const b: 0 | 1 = Enum([0, 1])[1];
const m: 'x' = Mid([true, 'x'])[0];
const f: (x: number) => number = Enum2([(x) => x])[0];
declare function Enum2<F extends ((x: number) => number)[]>(fs: [...F]): F;

const wrong: 'x' = Enum(['ts', 'js'])[0];
const widened: 'x' = Open(['x'])[0];

type Tail<T> = T extends [...infer A, { brand: undefined }] ? Tail<A> : T;

interface Service {
  create<T>(descriptor: { ctor: new () => T }): T;
  create<C extends new (...args: any[]) => unknown, R extends InstanceType<C>>(ctor: C, ...args: Tail<ConstructorParameters<C>>): R;
  plain<T extends string>(value: T, ...rest: number[]): T;
}

type Params<F> = F extends (...args: infer A) => any ? A : never;
type Result<F> = F extends (...args: any[]) => infer R ? R : never;

// The source's own parameters read as their constraints, and its rest element stays open.
declare const created: Params<Service['create']>;
export const fourth = created[3];
export const ctor: new (...args: any[]) => unknown = created[0];
export const made: unknown = null! as Result<Service['create']>;

declare const plain: Params<Service['plain']>;
export const value: string = plain[0];
export const extra: number = plain[4];

type Tuple = Params<(a: string, b?: number, ...rest: [boolean, ...string[]]) => void>;
declare const tuple: Tuple;
export const third: boolean = tuple[2];
export const later: string = tuple[9];

// A target with more parameters than its source leaves the rest empty.
type Short = ((a: string) => void) extends (a: string, b: number, ...rest: infer R) => void ? R : 'no';
export const short: Short = [];

// error: an unconstrained parameter is unknown, not any.
export const wrong: string = null! as Params<<T>(x: T) => void>[0];

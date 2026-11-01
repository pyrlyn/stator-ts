// A bare type parameter in a conditional branch is a weaker hint than the rest of the target.
type DeepValue<T> = T extends () => unknown ? T : { [K in keyof T]: DeepValue<T[K]> };

declare function create<T>(initial: DeepValue<T | (() => T)>): T;
const value = create(() => ({ ready: true }));
value.ready;
const r1: boolean = value;

declare function only<T>(x: DeepValue<T>): T;
const r2: boolean = only(() => 1);
declare function plain<T>(x: T | (() => T)): T;
const r3: boolean = plain(() => ({ ready: true }));
declare function either<T>(x: DeepValue<T | (() => T)>): T;
const r4: boolean = either({ a: 1 });

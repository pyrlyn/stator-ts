import { X } from 'nomodule';
import * as N from 'nomodule';
type Branded = { _b: undefined };
type L<A extends any[]> = A extends [] ? [] : A extends [...infer F, Branded] ? L<F> : A;
declare function make<C extends new (...args: any[]) => unknown>(c: C, ...args: L<ConstructorParameters<C>>): void;
class K { constructor(a: string, o: X | undefined, s: { _b: undefined }) {} }
class K2 { constructor(a: string, o: N.X | undefined, s: { _b: undefined }) {} }
class K3 { constructor(a: string, o: Y, s: { _b: undefined }) {} }
make(K, '1', undefined, 3);
make(K, '1');
make(K2, '1', undefined, 3);
make(K3, '1', undefined, 3);
type P1 = L<[string, X, Branded]>;
const p1: P1 = 1;
type E = X extends string ? 1 : 2;
const e: E = 3;
type E2 = N.X extends string ? 1 : 2;
const e2: E2 = 3;
const m1: { a: X } = 1;
const m2: X[] = 1;
type P2 = ConstructorParameters<typeof K>;
const p2: P2 = 1;
type P3 = L<ConstructorParameters<typeof K>>;
const p3: P3 = 1;
declare function make2<C extends any[]>(...args: L<C>): void;
declare function make3<C extends new (...args: any[]) => unknown>(c: C): L<ConstructorParameters<C>>;
const p4: number = make3(K);

import { X } from 'nomodule';
type Branded = { _b: undefined };
type L<A extends any[]> = A extends [] ? [] : A extends [...infer F, Branded] ? L<F> : A;
declare function make<C extends new (...args: any[]) => unknown>(c: C, ...args: L<ConstructorParameters<C>>): void;
class K0 { constructor(a: string, s: { _b: undefined }) {} }
class K1 { constructor(a: string, o: any, s: { _b: undefined }) {} }
class K2 { constructor(a: string, o: X, s: { _b: undefined }) {} }
class K3 { constructor(a: string, o: X, b: string) {} }
make(K0, '1', 2, 3);
make(K1, '1', 2, 3);
make(K2, '1', 2, 3);
make(K3, '1', 2, 3, 4);

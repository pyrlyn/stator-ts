// The inner call answers once, under the generic rest type it sees first: `any` there, so `R` is `any`.
type Brand = { _serviceBrand: undefined };
type Lead<A extends any[]> = A extends [] ? [] : A extends [...infer F, Brand] ? Lead<F> : A;
declare function make<C extends new (...args: any[]) => unknown, R extends InstanceType<C>>(ctor: C, ...args: Lead<ConstructorParameters<C>>): R;
interface N<T, F = void> { readonly element: T; readonly children: N<T, F>[]; readonly filterData: F | undefined; }
interface Rn<T, F = void, D = void> { renderElement(e: N<T, F>, i: number, d: D): void; }
class R1 implements Rn<string, [number, number], {}> {
  private x = 1;
  renderElement(e: N<string, [number, number]>, i: number, d: {}) {}
}
class Tree<T extends NonNullable<any>, F = void> {
  constructor(u: string, rs: Rn<T, F, any>[], o: { a?: T; f?: F }, s: Brand) {}
}
const quiet = make(Tree<string, void>, 'u', [make(R1)], {});
const loud = make(Tree<string, void>, 'u', [new R1()], {});
const wrong: number = quiet;

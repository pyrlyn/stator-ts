class Base<T> {
  constructor(public v: T) {}
  get(): T { return this.v; }
}
const Alias = Base;
class D extends Alias<string> {}
const n: number = new D("a").get();
new D(1);
const Made = (() => Base)();
class E2 extends Made<number> {}
const s: string = new E2(1).get();

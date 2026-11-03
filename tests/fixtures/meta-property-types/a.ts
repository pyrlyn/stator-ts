export function f(this: unknown) {
  const self: number = new.target;
  return () => new.target;
}
export class C {
  made = 1;
  constructor() {
    const ctor: string = new.target;
    new.target.made2;
  }
  method() {
    return new.target;
  }
  field = new.target;
  static {
    new.target;
  }
}
export const url = import.meta.url;
export const named: number = import.meta;
new.target;
function plain() {
  return this;
}
const o: { f?: () => void; g: number } = { g: 1 };
o.f = function () {
  this.g;
  this.nope;
};
function g() {
  const x: never = this;
  return 1 + undefined;
}
export { plain, g };

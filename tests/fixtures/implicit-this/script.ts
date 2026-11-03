function plain() {
  return this;
}
const expr = function () {
  return this;
};
function annotated(this: { a: number }) {
  return this.a;
}
const obj = {
  m() { return this; },
  f: function () { return this; },
};
const target = { x: 1, g: undefined as unknown };
target.g = function () { return this.x; };
target.g ??= function () { return this.x; };
const cb: (this: Date) => void = function () { this.getTime(); };
const top = () => this;
namespace NS {
  export const v = this;
}
enum E {
  A = this,
}
class K {
  [String(this)]() {}
  m() { return () => this; }
}

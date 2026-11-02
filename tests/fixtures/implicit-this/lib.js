function Ctor(a) {
  this.a = a;
}
/** @this {{ a: number }} */
function withThis() {
  return this.a;
}
/** @type {(this: Date) => number} */
const typed = function () {
  return this.getTime();
};
export { Ctor, withThis, typed };

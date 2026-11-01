const open: [string?, number?] = [];
open.length = 0;
declare const closed: readonly [string?];
closed.length = 0;
class C {
  readonly a: number = 1;
  clear() {
    (this.a as unknown) = null;
    (this.a) = 2;
  }
}
namespace N {
  export function fn() {}
  export class K {}
  export enum E { A }
  export const c = 1;
}
N.fn = () => {};
N.K = class {};
N.E = N.E;
N.c = 2;
globalThis.clearInterval = globalThis.clearInterval;
export { C };

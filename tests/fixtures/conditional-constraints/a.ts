// `Awaited<T>` reads as `T`: its thenable branch has nothing to infer from, and comes out `never`.
function viaAwaited<T>(x: Awaited<T>): T {
  return x;
}
function viaUnion<T>(x: Awaited<T> | undefined): T | undefined {
  return x;
}
function notTheOther<T, U>(x: Awaited<T>): U {
  return x;
}
// One `any` branch must not make the whole conditional assignable to everything.
type OneAny<T> = T extends string ? any : number;
function elided<T>(x: OneAny<T>): boolean {
  return x;
}
function kept<T>(x: OneAny<T>): number {
  return x;
}
// Distributive over a constrained parameter: the constraint settles what both branches could not.
type Pick1<T> = T extends string ? 'text' : T extends number ? 'num' : boolean;
function bound<T extends string>(x: Pick1<T>): 'text' {
  return x;
}
function loose<T>(x: Pick1<T>): 'text' {
  return x;
}
// The constraint is only an upper bound, so a branch it could still reach stays in.
type Tag<T> = T extends { a: 1 } ? 'a' : 'b';
function reached<T extends object>(x: Tag<T>): 'b' {
  return x;
}
function both<T extends object>(x: Tag<T>): 'a' | 'b' {
  return x;
}

class A {
  static s = 1;
  static m(): string { return ""; }
  i = 1;
}
class B extends A {
  static {
    const n: string = super.s;
    const r: number = super.m();
    super.i;
  }
  static x = super.m();
}

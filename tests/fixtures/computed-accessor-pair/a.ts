const k = "v";
class C {
  get [k](): number { return 1; }
  set [k](x: number) {}
  get ro(): number { return 1; }
  get [Symbol.toStringTag](): string { return "C"; }
}
const c = new C();
c[k] = 2;
c.v = "a";
c.ro = 2;
const o = {
  get [k]() { return 1; },
  set [k](x: number) {},
};
o.v = 2;
o.v = "a";

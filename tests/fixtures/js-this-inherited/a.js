class Base {
  constructor() {
    this.raw = 0;
    this.other = 'o';
  }
  get value() {
    return this.raw;
  }
  set value(v) {
    this.raw = v;
  }
}
class Derived extends Base {
  get value() {
    return this.raw * 2;
  }
  set value(v) {
    v.nothing;
    this.raw = v + 1;
  }
  later() {
    this.other = 1;
  }
}
const d = new Derived();
d.raw.nothing;
d.value.nothing;
d.other.nothing;

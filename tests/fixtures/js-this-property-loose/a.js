class Base {
  /** base */
  constructor() {
    this.fromBase = 'x';
  }
}

class Point extends Base {
  declared;
  #hidden;
  constructor(x) {
    super();
    this.count = 1;
    this.name = 'a';
    this.maybe = null;
    this.x = x;
    this.fromBase = 'y';
    this['keyed'] = true;
    this.declared = 2;
    this.#hidden = 3;
  }
  grow() {
    this.count = this.count + 1;
    this.late = 'b';
    this.maybe = 5;
    this.notString = 1;
    return this.#hidden;
  }
  static make() {
    this.shared = 1;
    return new Point(0);
  }
  later = (this.fromField = 1);
}

const p = new Point(1);
const a1 = p.count.toFixed(2);
const a2 = p.name.toUpperCase();
const a3 = p.late.length;
const a4 = p.maybe;
const a5 = p.fromBase.length;
const a6 = p.keyed;
const a7 = p.declared.toFixed();
const a8 = Point.shared.toFixed();
const a9 = p.shared;
const a10 = p.missing;
const a11 = p.notString.length;
const a12 = p.fromField.toFixed();

class Replaced {
  constructor() {
    this.m = 1;
  }
  m() {
    return 'm';
  }
}
const r = new Replaced().m().length;

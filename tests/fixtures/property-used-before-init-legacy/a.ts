class Base {
  b = 1;
}

class A extends Base {
  x: number;
  y = this.x;
  z = this.w;
  w = 1;
  v = () => this.w2;
  w2 = 2;
  i = (() => this.w3)();
  w3 = 3;
  self = this.self;
  o?: number;
  p = this.o2;
  o2?: number;
  m = this.method();
  q = this.b;
  nested = this.later.toFixed();
  later = 1;
  static s = A.t;
  static t = 1;
  static m = A.f();
  static f() { return 1; }
  static g = A.acc;
  static get acc() { return 1; }
  static {
    A.u;
  }
  static u = 1;
  static {
    A.t;
  }
  method() { return this.w; }
  constructor() {
    super();
    this.x = 1;
  }
}

class P {
  before = this.pp;
  constructor(public pp: number) {}
  after = this.pp;
}

class Q {
  r = this.later;
  static k = Q.inst;
  inst = 1;
  later!: number;
}
new Q().k;

class R {
  getterName: any = {
    get [this.getterName]() { return true; },
  };
  static fromLiteral = Lit.a;
}

const Lit = { a: 0 };

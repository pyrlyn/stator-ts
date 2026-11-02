class Base { constructor(public n?: unknown) {} m() { return 1; } }
class A extends Base {
    x = 1;
    constructor() {
        this.x = 100;
        super.m();
        super();
        this.x = 10;
    }
}
class B extends Base {
    constructor(a: boolean) {
        if (a) super(); else super();
        this.m();
    }
}
class C extends Base {
    constructor(a: boolean) {
        if (a) super();
        this.m();
    }
}
class D extends Base {
    constructor() {
        super(this);
    }
}
class E extends Base {
    constructor() {
        const f = () => this;
        super(f);
    }
}
class F extends Base {
    constructor(p = this) {
        super();
    }
}
class G extends Base {
    constructor() {
        const v = (super(), this);
        for (let i = 0; i < 1; i++) this.m();
    }
}
class H extends Base {
    constructor() {
        try { super(); } finally { }
        this.m();
    }
}

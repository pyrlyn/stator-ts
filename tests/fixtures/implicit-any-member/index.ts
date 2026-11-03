export class FromConstructor {
    a;
    b;
    c;
    0;
    constructor(seed: number, flag: boolean) {
        this.a = seed;
        this["b"] = [seed];
        if (flag) this.c = "x";
        this[0] = seed;
    }
}

export class NeverAssigned {
    a;
    b;
    constructor() {
        this.b = null;
    }
}

export class NoConstructor {
    a;
    static s;
}

export class FromStaticBlock {
    static a;
    static b;
    static {
        this.a = 1;
    }
}

export interface Shape {
    width;
    height: number;
}

declare class Ambient {
    private hidden;
    shown;
}

const n: string = new FromConstructor(1, true).a;
const s: string = FromStaticBlock.a;
export { n, s, Ambient };

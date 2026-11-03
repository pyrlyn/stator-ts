declare const dec: any;

export class Legacy {
    @dec field = 1;
    @dec #hidden = 2;
    @dec method(@dec x: number) { return x + this.#hidden; }
    constructor(@dec value: number) { void value; }
}

export const Expr = @dec class {
    @dec method() {}
};

export function free(@dec x: number) { return x; }

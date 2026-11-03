declare const dec: any;

@dec enum Color { Red }
@dec interface Shape {}
@dec type Alias = number;
@dec function free() {}
@dec namespace Space {}

@dec
export class Valid {
    @dec field = 1;
    @dec accessor auto = 2;
    @dec method() {}
    @dec get value() { return 1; }
    @dec static #hidden() {}
}

export const Expr = @dec class {};

export abstract class Invalid {
    @dec constructor(@dec value: number) { void value; }
    @dec abstract field: number;
    @dec declare other: number;
    @dec overload(): void;
    overload() {}
    @dec static {}
    method(@dec param: number) { return param; }
}

export { Color, Shape, Alias, free, Space };

// Index signature parameters have no function to own a `this` parameter.
export interface Indexed { [key: string]: number }

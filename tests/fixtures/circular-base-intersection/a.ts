type J = A & B;
interface A {}
interface B {}
interface I extends J, K {}
interface K extends I {}
declare const i: I;
const a: A = i;
interface M extends N {}
interface M { x: 1 }
interface N extends M {}
interface P extends Q {}
interface Q extends R {}
interface R extends P {}

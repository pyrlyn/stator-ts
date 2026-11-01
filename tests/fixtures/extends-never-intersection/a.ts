type J = { kind: "a" } & { kind: "b" };
interface I extends J {}
declare const i: I;
const s: string = i.kind;

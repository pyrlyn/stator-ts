export enum E {
    A = 1 / 0,
    B = ~A,
    C = A | 1,
    D = (0 / 0) << 1,
}
const b: E.B = E.B;
export { b };

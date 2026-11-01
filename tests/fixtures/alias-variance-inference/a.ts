// An alias hands inference only its arguments, so `Eq<T>` has to count as contravariant.
interface ISel { a: number }
declare class Sel implements ISel { a: number; isEmpty(): boolean; static eq(x: ISel, y: ISel): boolean; }
interface Obs<T> { read(r: unknown): T }
type Eq<T> = (a: T, b: T) => boolean;
type Get<T> = () => T;
type Both<T> = (a: T) => T;
declare function derived<T>(options: { equalsFn?: Eq<T> }, computeFn: (r: string) => T): Obs<T>;
declare function ifDefined<T>(eq: Eq<T>): Eq<T | undefined | null>;
declare function sels(): Sel[] | undefined;
declare function mix<T>(a: Get<T>, b: Eq<T>): T;
declare function keep<T>(a: Both<T>, b: T): T;
declare const getSel: Get<Sel>;
declare const eqSel: Eq<ISel>;
declare const bothSel: Both<ISel>;
declare const sel: Sel;

const x = derived({ equalsFn: ifDefined(Sel.eq) }, r => sels()?.[0]);
const n1: number = x;
const y = derived({ equalsFn: Sel.eq }, r => sels()![0]);
const n2: number = y;
const z = derived({ equalsFn: Sel.eq as Eq<ISel> }, () => sels()![0]);
const n3: number = z;
const n4: number = mix(getSel, eqSel);
const n5: number = keep(bothSel, sel);

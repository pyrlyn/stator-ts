interface Base { id: string }
interface Sub extends Base { extra: number }

// A constraint on the source must be met by what the target says, by inference.
type GetBase = <T extends Base>() => T;
type GetOptional = () => Sub | undefined;
declare const get: GetBase;
const optional: GetOptional = get;

type Provider = { provide<T extends Base>(name: string): T };
type Lookup = { provide(name: string): Sub | undefined };
declare const provider: Provider;
const lookup: Lookup = provider;

// A return position only wishes for a type, the members that fit still count.
declare function make<T extends Base>(): T;
const fits: Sub | undefined = make();
const fitsNull: Sub | null = make();
const noneFit: string | undefined = make();
const wrongAlone: string = make();

declare function pick<T extends string>(): T;
const literal: 'a' | 1 = pick();
const notString: 1 | 2 = pick();

// Generic to generic stays by inference, not by parameter position.
type First = <A, B>(a: A, b: B) => A;
type Second = <X>(a: X, b: string) => X;
declare const first: First;
const second: Second = first;
type Swapped = <X>(a: string, b: X) => X;
const swapped: Swapped = first;

// `T | undefined` still says `T` when the constraint rejects the union, and an argument hears it.
interface Elem { tag: string }
interface Button extends Elem { click(): void }
interface Other { id: number }

declare function make<T extends Elem>(d: string): T;
declare function one<T extends Elem>(c: T): T;
declare function two<T>(c: T): T;
declare function three<T extends Elem>(c: T): T | undefined;

const a1: Button = one(make('x'));
const a2: Button | undefined = one(make('x'));
const a3: Button | undefined = two(make('x'));
const a4: Button | undefined = make('x');
const a5: Button | undefined = three(make('x'));

// A union with nothing that fits the constraint still falls back to it.
const b1: Other | undefined = one(make('x'));
const b2: string | undefined = one(make('x'));

declare function take(r: Record<string, string>): void;
declare const c: boolean;

const attrs = c ? { a: 'x', b: 'y' } : {};
take(attrs);
const either = c ? { a: 'x' } : { b: 'y' };
take(either);
const undef: string | undefined = attrs.a;

declare const written: { a?: undefined };
take(written);
const literal = { a: undefined };
take(literal);
const number = c ? { a: 1 } : { b: 'y' };
take(number);

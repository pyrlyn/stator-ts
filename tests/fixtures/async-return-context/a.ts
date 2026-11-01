type Handler<T> = () => Promise<T> | string;
declare function run<T>(handler: Handler<T>): T;

// An async function can only produce the promise, so `string` gives no context.
const literal = run(async () => 'a');
const wrong: number = literal;

const typed: () => Promise<'a' | 'b'> | number = async () => 'a';
const bad: () => Promise<'a' | 'b'> | number = async () => 'c';
const onlyOthers: () => string = async () => 'c';

type Maybe = (() => Promise<(x: number) => void>) | undefined;
const callback: Maybe = async () => (x) => x.toFixed();

// A context that is a promise as a whole keeps the literal, a union of promises too.
const whole: () => Promise<'a' | 'b'> = async () => 'a';
const both: () => Promise<'a'> | Promise<'b'> = async () => 'a';

// Object literals written side by side unite instead of one having to be a supertype of the rest.
export const handlers = new Map([
	['a', { ro: true, handle: async () => 1 }],
	['b', { ro: false, handle: async () => null }],
	['c', { ro: true, needs: true, handle: async () => 's' }],
]);
declare function pairs<V>(x: [string, V][]): V;
const wrong: number = pairs([['a', { a: 1 }], ['b', { a: 's' }]]);

// A literal still waiting for its lambda does not vote, so the `this` type gives it context.
function rec(this: { a(x: string, y: number): void }) { }
declare function bind<T, R>(fn: (this: T) => R, thisArg: T): R;
bind(rec, { a: (u, v) => { u.length; v.toFixed(); } });

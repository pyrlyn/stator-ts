// `path` says `export = path`, and `join` is a property of that value, not an export. Typing it
// `any` turns the assignment below into "assigned any", which keeps the declared type.
import { join } from 'node:path';
import { once } from 'events';

declare function take(x: string): void;

export function assigned() {
	process.env['A'] = process.env['A'] || join('a', 'b');
	take(process.env['A']);
}

export function called(em: import('events').EventEmitter) {
	return once(em, 'x').then(args => args.length);
}

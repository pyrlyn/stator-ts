// A union of one shape and things with nothing to spread reads as that shape made optional.
interface Config {
	headers?: Record<string, string>;
	endpoint?: string;
}
declare const config: Config;
declare const flag: boolean;
declare const opt: { a: number; method(): void } | undefined;

const fromOptional = { ...opt };
const fromAnd = { ...(flag && { a: 1 }) };
const overExisting = { a: 'x', ...(flag ? { a: 1 } : {}) };
const emptyBoth = { ...(flag ? {} : {}) };
const twoShapes = { ...(flag ? { a: 1 } : { b: 2 }) };

const n1: number = fromOptional;
const n2: number = fromAnd;
const n3: number = overExisting;
const u1: { a: number } = fromOptional;
const u2: { a?: number } = fromAnd;
const u3: { a: string | number } = overExisting;

declare function pick<T extends Record<string, unknown>>(keys: T): Promise<{ [K in keyof T]: string | undefined }>;
const KEY = 'a.b';
const OTHER = 'c.d';
async function keysThroughSpread() {
	const m = await pick({ [OTHER]: true, ...(flag ? {} : { [KEY]: true }) });
	return m[KEY];
}

// `as const` reaches a shorthand property, and a spread inherits it.
const protocol = flag ? 'grpc' : 'http';
const constant = { protocol, ...(config.headers ? { headers: config.headers } : {}) } as const;
const kept: { readonly protocol: 'grpc' | 'http'; readonly headers?: Record<string, string> } = constant;
declare const copy: { protocol: 'grpc' | 'http' };
constant.headers = {};

// The rest of a discriminated match can be spread over an intersection.
type Options = ({ isolation: 'folder' } | { isolation: 'worktree'; prompt: string; force?: boolean }) & { source?: string };
declare function prepare(options: Options): void;
prepare({ isolation: flag ? 'worktree' : 'folder', force: flag, prompt: '', ...(flag ? { source: 's' } : {}) });
prepare({ isolation: flag ? 'worktree' : 'folder', force: 1, prompt: '' });

type Status =
	| { readonly kind: 'connected' }
	| { readonly kind: 'failed'; readonly message: string }
	| { readonly kind: 'old'; readonly method?: string; readonly message: string };

function isOld(s: Status | undefined): s is Status & { kind: 'old' } {
	return s?.kind === 'old';
}

declare const status: Status | undefined;
if (isOld(status)) {
	status.method;
	status.message.trim();
}

type Tool = { status: 1; a: string } | { status: 2; auth: { name: string } };
export function auth(t: Tool & { status: 2 }): string {
	return t.auth.name;
}

enum St { Run, Done, Auth }
type Call = { status: St.Run; a: string } | { status: St.Auth; auth: { name: string } } | { status: St.Done };
export function byEnum(t: Call & { status: St.Auth }): string {
	return t.auth.name;
}

export const none: { kind: 'a' } & { kind: 'b' } = null as never;

// `failed` stays; a real error, since not every member has a message.
export const fine: Status & { kind: 'failed' } = { kind: 'failed', message: 'x' };
declare const kept: Status & { kind: string };
kept.message;

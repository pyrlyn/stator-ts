// `{}` left by removing undefined from `unknown` has no index, so a guard to a
// string index replaces it rather than keeping it.
function isRecord(v: unknown): v is Record<string, unknown> {
    return typeof v === 'object' && v !== null;
}
declare const value: { receipt?: unknown };
export const queued = value.receipt === undefined || (isRecord(value.receipt) && value.receipt.kind === 'queued');

declare const raw: unknown;
if (raw !== undefined && raw !== null && isRecord(raw)) {
    raw.kind;
}

declare const empty: {};
if (isRecord(empty)) {
    empty.kind;
}

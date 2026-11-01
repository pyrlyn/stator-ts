// `a ?? true` is a default, not a constant, while a plain `|| true` is.
const enum K { No, Found }
type R = { kind: K.No } | { kind: K.Found; commandId: string | null };
declare const s: R;
declare const o: { a?: boolean };

if (s.kind === K.Found && s.commandId && !(o.a ?? true) && ['x'].includes(s.commandId)) { }
if (s.kind === K.Found && !(o.a ?? true) && s.commandId) { }
if (s.kind === K.Found && (o.a ?? true) && s.commandId) { }
if (s.kind === K.Found && !(o.a && true) && s.commandId) { }
if (s.kind === K.Found && !(o.a || true) && s.commandId) { }

// The left side still narrows the right one.
declare const c: { modified?: number; original: number } | { modified: number; original?: number };
const index = c.modified ?? c.original;
const sum = index + 1;

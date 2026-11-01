export const a: { p: 'a' } = { get p() { return 'a'; } };
export const b: { p: 'a' } = { get p() { return 'a' as const; } };
export const c: { p(): 'a' } = { get p() { return () => 'a'; } };
export const d: { p: (x: number) => void } = { get p() { return (x) => { }; } };
export const e: { p: string } = { set p(v) { v.length; }, get p() { return ''; } };
export const g: { p: string[] } = { get p() { return []; } };
export class K { get a() { return 'x'; } set a(v) { v.length; } }
export const h: { p(): string } = { p() { return 1; } };
export const i: { p: string } = { p() { return 1; } };
export const j: { q: { p: string } } = { q: { get p() { return 1; } } };

declare function pr(): Promise<string[]>;
export function k(): Promise<string[]> { return pr() || []; }
export function l(): Promise<string[]> { return pr() ?? []; }
declare const o: { a: 1 } | undefined;
export const w: { a: 1 } | number = o || 0;
declare const e: {};
export const a: {} | number = e || 0;
export const b: string = e || 0;

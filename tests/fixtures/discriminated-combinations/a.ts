interface PA { storage: 'local'; uri: string; source: 'x' | 'y' }
interface PB { storage: 'user'; uri: string; source: 'x' | 'y'; opt?: number }
interface PC { storage: 'ext'; uri: string; ext: number; source: 'z' }
type P = PA | PB | PC;
declare const sd: { storage: 'local' | 'user'; uri: string; source: 'x' };
const p1: P = sd;
declare const sb: { storage: 'local' | 'ext'; uri: string; source: 'x' };
const p2: P = sb;
type Q = { a: 1; b: 'x' } | { a: 2; b: 'y' };
declare const q: { a: 1 | 2; b: 'x' | 'y' };
const q1: Q = q;
declare const r: { a: 1 | 2; b: 'x' };
const r1: Q = r;

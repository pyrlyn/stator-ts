const ROOT = 'ahp-root://';
interface Base { channel: string; meta?: unknown }
interface ReadP extends Base { channel: 'ahp-root://'; uri: string }
interface ListP extends Base { channel: 'ahp-root://'; dir: string }
interface PingP extends Base { n: number }
interface M1 { read: { params: ReadP }; list: { params: ListP } }
interface M2 { ping: { params: PingP } }
type R1<K extends keyof M1 = keyof M1> = K extends unknown ? { readonly id: number; readonly method: K; readonly params: M1[K]['params'] } : never;
type R2<K extends keyof M2 = keyof M2> = K extends unknown ? { readonly id: number; readonly method: K; readonly params: M2[K]['params'] } : never;
type Msg = R1 | R2;
declare function fire(m: Msg): void;
fire({ id: 1, method: 'read', params: { channel: ROOT, uri: 'x' } });
fire({ id: 1, method: 'list', params: { channel: ROOT, dir: 'x' } });

type Shape = { kind: 'a'; run(x: number): void } | { kind?: undefined; run(x: string): void };
export const left: Shape = { kind: 'a', run(x) { x.toFixed(); } };
export const right: Shape = { run(x) { x.trim(); } };

const kind = 'a';
export const short: Shape = { kind, run(x) { x.toFixed(); } };

// Still real errors.
fire({ id: 1, method: 'read', params: { channel: ROOT, uri: 1 } });
export const wrong: Shape = { kind: 'a', run(x) { x.trim(); } };

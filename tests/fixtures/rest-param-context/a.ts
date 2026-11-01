interface S { exec<R = unknown>(id: string, ...args: unknown[]): Promise<R | undefined>; }
const cmds: Parameters<S['exec']>[] = [];
const s: S = { exec: async (...args) => { cmds.push(args); return undefined; } };
declare function stub<T>(id: T, o: Partial<NoInfer<T>> | Function): T;
declare const sv: S;
stub(sv, { exec: async (...args) => { cmds.push(args); return undefined; } });
interface Ctx { readonly on: (model: string, ...change: Parameters<(a: string, b: string, c?: unknown, d?: number) => void>) => void; }
const ch: Parameters<Ctx['on']>[] = [];
const x: Ctx = { on: (...change) => ch.push(change) };
const y: Partial<Ctx> = { on: (...change) => ch.push(change) };
const n: number = ch;

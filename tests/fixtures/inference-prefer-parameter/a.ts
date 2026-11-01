interface Acc { get(): void }
interface Svc { invokeFunction<R, TS extends any[] = []>(fn: (accessor: Acc, ...args: TS) => R, ...args: TS): R; }
declare const svc: Svc;
const make = (accessor: Acc, data: ({ from: 'model'; uri: string } | { from: 'raw'; text: string | undefined; config: {}; uri?: string } | { from: 'file'; f: string })): number => 1;
declare const results: string | undefined;
export const n = svc.invokeFunction(make, { from: 'raw', text: results, config: {} });

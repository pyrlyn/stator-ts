// A nested conditional in an argument stays as written: only a declaration
// adds `'X-Y'?: undefined` to the `{}` branch.
type Headers = [string, string][] | Record<string, string>;
interface Init { status?: number; headers?: Headers }
declare function json(d: unknown, i?: Init): void;
declare const exp: string | undefined;
json({}, { headers: exp === undefined ? {} : { 'X-Y': exp } });
json({}, { status: 1, headers: exp === undefined ? {} : { 'X-Y': exp } });
const c = exp === undefined ? {} : { 'X-Y': exp };
export const d: Headers = c;

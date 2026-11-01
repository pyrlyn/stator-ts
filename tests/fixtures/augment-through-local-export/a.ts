import { config, type Renamed, type UserConfig } from './m';

declare module './m' {
  interface UserConfig {
    test?: { root: string };
  }
  interface Renamed {
    b: string;
  }
  interface Fresh {
    c: number;
  }
}

const ok: UserConfig = { name: 'a', test: { root: 'x' } };
const root = config.test?.root;
declare const r: Renamed;
r.b;
r.a;
declare const f: import('./m').Fresh;
f.c;
const bad: UserConfig = { test: {} };
const unknown: UserConfig = { other: 1 };

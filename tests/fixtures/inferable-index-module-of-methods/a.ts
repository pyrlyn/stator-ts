import * as family from './e';
import type { E } from './t';

type Method = (emitter: E, ...args: never[]) => unknown;
declare function methods(f: Record<string, Method>): void;
methods(family);

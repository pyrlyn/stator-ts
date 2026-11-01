import * as family from './e';
import * as mixed from './n';
import type { E } from './e';

type Method = (emitter: E, ...args: never[]) => unknown;
declare function methods(f: Record<string, Method>): void;
declare function strings(f: Record<string, string>): void;
declare function anything(f: { [k: string]: unknown }): void;

methods({ f: family.f, g: family.g });
anything(mixed);
strings(mixed);

enum Color {
  Red = 'r',
  Green = 'g',
}
enum Size {
  S,
  L,
}
declare function colors(f: Record<string, Color>): void;
colors(Color);
colors(Size);

namespace Space {
  export const a = 'a';
}
strings(Space);

function callable(): void {}
namespace callable {
  export const a = 'a';
}
strings(callable);

class Cls {
  static a = 'a';
}
namespace Cls {
  export const b = 'b';
}
strings(Cls);

type WithCall = { (): void; a: string };
declare const withCall: WithCall;
strings(withCall);

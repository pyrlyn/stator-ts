// A missing implementation, and one that is not right after its overloads.
function missing(x: string): void;

function apart(x: string): void;
const between = 1;
function apart(x: string) {}

// The implementation has another name.
function first(x: number): void;
function second(x: number) {}

// Two implementations.
function twice() {}
function twice() {}

// An overload the implementation cannot serve.
function narrow(x: string): string;
function narrow(x: number): number {
  return x;
}

// Overloads that disagree on modifiers.
export function exported(): void;
function exported(): void;
export function exported() {}

declare function ambient(): void;
function ambient(): void;
function ambient() {}

class Members {
  constructor(x: string);

  method(): void;
  other() {}

  private hidden(): void;
  public hidden(): void;
  hidden() {}

  static flip(): void;
  flip(): void {}

  optional?(): void;
  optional(): void;
  optional() {}
}

class Ctors {
  constructor() {}
  constructor(x?: number) {}
}

abstract class Abstract {
  abstract run(): void;
  walk() {}
  abstract run(x: number): void;
}

// Fine: a matching list, an ambient list and an abstract method.
function ok(x: string): string;
function ok(x: number): number;
function ok(x: string | number) { return x; }
declare function amb(x: string): void;
declare function amb(x: number): void;
abstract class Fine {
  abstract go(): void;
}

void [between, missing, first, second, twice, narrow, ambient, ok, amb, Members, Ctors, Abstract, Fine];

// Interface and type literal overloads agree on `?` too.
interface Sigs {
  maybe?(): void;
  maybe(x: string): void;
}
type Lit = {
  maybe(): void;
  maybe?(x: string): void;
};

// Each namespace block needs its own implementation.
namespace Twice {
  export function part(): void;
}
namespace Twice {
  export function part(): void;
  export function part() {}
}

declare const flag: boolean;
declare const value: unknown;

function primitives<T extends number, U extends 0 | 1 | 2>(thing: T & U, other: T & (0 | 1 | 2)) {
  "key" in thing;
  "key" in other;
}

function objects<T extends object, U>(thing: T & U, plain: T) {
  "key" in thing;
  "key" in plain;
}

function generic<T>(thing: T) {
  "key" in thing;
}

function keys(target: object) {
  flag in target;
  0 in target;
  Symbol.iterator in target;
  "key" in 1;
}

class Box {
  #inner = 1;
  has(v: object) {
    return #inner in v;
  }
}

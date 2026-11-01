interface Weak { a?: number; b?: string }

function isObj(x: unknown): x is Object {
  return typeof x === 'object';
}

declare const u: unknown;
declare const n: any;
declare function take(w: Weak): void;

if (isObj(u)) take(u);
if (isObj(n)) take(n);
if (n instanceof Object) {
  const kept: boolean = n;
  take(n);
}
take(1);

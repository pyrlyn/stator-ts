declare function ambient({ a, b }?: { a: number; b: string }): void;
declare function ambientTuple([]?: [x: string]): void;
declare function ambientUnion({ a }: { a: number } | undefined): void;
declare function ambientNested({ inner: { c } }: { inner: { c: number } } | undefined): void;

function implemented({ a }?: { a: number }) {
  const s: string = a;
  return s;
}

function defaulted({ a }: { a: number } = { a: 1 }) {
  const s: string = a;
  return s;
}

ambient();
ambientTuple(['x']);
ambientUnion(undefined);
ambientNested(undefined);
implemented();
defaulted();

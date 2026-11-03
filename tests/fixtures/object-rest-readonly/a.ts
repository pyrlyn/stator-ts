interface Parts {
  readonly kept: string;
  readonly gone?: number;
}

declare const parts: Parts;
const { kept, ...rest } = parts;
delete rest.gone;
rest.gone = 1;
parts.gone = 2;

const full: Readonly<{ a: string; b?: string }> = { a: "x" };
const { a, ...others } = full;
others.b = "y";
delete full.b;

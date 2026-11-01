declare function run(cb: (x: number) => void): void;
run((x, extra?) => extra.foo);
run((x, extra = 1) => extra.toFixed());
export {};

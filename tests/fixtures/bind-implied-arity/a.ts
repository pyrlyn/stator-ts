function add(a: number, b: string, c: boolean): string { return ""; }
const b1 = add.bind(null, 1);
const r1: number = b1("a", true);
b1(1, true);
const b2 = add.bind(null, 1, "a");
b2(1);
const c1 = add.call(null, 1, "a", true);
const c2: number = c1;
add.apply(null, [1, "a"]);

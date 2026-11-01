const ok: [...string[], number] = ["a", "b", 1];
const bad: [...string[], number] = ["a", "b", "c"];
declare function f(...args: [...string[], number]): void;
f("a", "b", 1);
export {};

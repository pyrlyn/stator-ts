let s = "";
let n = 0;
let b = false;
declare const pair: [number, string];
declare const obj: { x: string; y?: number; z: boolean };
declare const list: string[];
let rest: { y?: number; z: boolean };
let more: number[];

[n, s] = pair;
[s, n] = pair;
({ x: s, z: b } = obj);
({ x: n } = obj);
({ y: n = 1 } = obj);
({ y: n } = obj);
({ x: s, ...rest } = obj);
[s, ...more] = list;
[n] = list;
({ z: [n] } = { z: [true] });

for (s of list) {}
for (n of list) {}
for ([n, s] of [pair]) {}
for ({ x: n } of [obj]) {}

let x = 0;
({ x } = obj);
({ x = "" } = obj);
[n = "a"] = [1];

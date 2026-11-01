const enum Tool { Create = "create", Send = "send", Other = "other" }
type Call =
	| { toolName: Tool.Create; id: string; input: { prompt: string } }
	| { toolName: Tool.Send; id: string; input: { prompt: string } };
declare function map(a: unknown, b: undefined, c?: ReadonlyMap<string, readonly Call[]>): void;
map(1, undefined, new Map([
	["a", [{ toolName: Tool.Create, id: "x", input: { prompt: "p" } }]],
	["b", [{ toolName: Tool.Send, id: "y", input: { prompt: "q" } }]],
]));
const m2: ReadonlyMap<string, readonly Call[]> = new Map([
	["a", [{ toolName: Tool.Create, id: "x", input: { prompt: "p" } }]],
	["b", [{ toolName: Tool.Send, id: "y", input: { prompt: "q" } }]],
]);
const m3 = new Map([
	["a", [{ toolName: Tool.Create, id: "x" }]],
	["b", [{ toolName: Tool.Send, id: "y" }]],
]);
const z3: "zz" = m3;
declare function pick<T>(a: T, b: T): T;
declare const opt: string[];
const p1 = pick([1], opt);
const p2 = pick(opt, [1]);
const p3 = pick([1], ["a"]);
const zp3: "zz" = p3;
const p4 = pick([1, 2] as const, [3] as const);
const zp4: "zz" = p4;
const p5 = pick([1], [2]);
const zp5: "zz" = p5;
const p6 = pick([{ a: 1 }], [{ b: 2 }]);
const zp6: "zz" = p6;
const p7 = pick([], [1]);
const zp7: "zz" = p7;
const p8 = pick([[1]], [["a"]]);
const zp8: "zz" = p8;
const p9 = pick({ x: [1] }, { x: ["a"] });
const zp9: "zz" = p9;
declare function waits<T extends [(p: number) => number]>(p: T): T;
const waited = waits([x => x]);

declare const rec: Record<string, { a: number }>;
declare const k: string;
declare const n: number;
declare const u: symbol;

const spreadThenKey = { ...rec, [k]: { a: 1 } };
const fromEntries = Object.entries(spreadThenKey).map(([, v]) => v.a);
const bad1: number = spreadThenKey['x'];

const beside = { a: 1, [k]: 'x' };
const bad2: boolean = beside['y'];

const keyThenSpread = { [k]: { a: 1 }, ...rec };
const bad3: number = keyThenSpread['z'];

const noKey = { ...rec, a: 1 };
const bad4: boolean = noKey['w'];

const numeric = { 1: 'a', b: true, [n]: 2 };
const bad5: boolean = numeric[3];
const bad6: boolean = numeric['c'];

const sym = { a: 1, [u]: 'x' };
declare const v: symbol;
const bad7: number = sym[v];

const noOther = { [n]: 1, a: 'x' };
const bad8: string = noOther['q'];

const method = { [k]() { return 1; }, b: 'x' };
const bad9: boolean = method['q'];

const twoRuns = { [k]: 1, ...{ [k]: 'x' }, [k]: true };
const bad10: boolean = twoRuns['q'];


const enum Kind { One, Two }
type Answer = { state: Kind.One } | { state: Kind.Two; value: string };
declare function record(answers: Record<string, Answer>): void;
record({ [k]: { state: Kind.One } });
record({ [k]: { state: Kind.Two } });

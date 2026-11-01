// Keys of a numeric index are numbers at heart, and an object literal knows all of its values.
declare const list: string[];
declare const rec: { [n: number]: string };
declare const both: { [n: number]: string; [s: string]: string | number };
declare const named: { [s: string]: number };
declare let key: string;
declare let num: number;

for (const i in list) {
	const a: number = list[i];
	const b: number = rec[i];
	const c: number = both[i];
	const d: string = named[i];
	const inner = () => list[i];
}
for (const i in rec) {
	const a: number = list[(i)];
}
for (key in list) {
	const a: number = list[key];
}
for (const i in both) {
	const a = list[i];
}

const widened = { a: 1, b: 'x' };
const l1: boolean = widened[key];
const l2 = widened['nope'];

const e1 = {}[key];
const e2: number = ({ x: 1 })[key];
const e3 = ({ x: 1 })['y'];
function viaAssertion<T>(k: string) {
	return ({ a: 1 }[k] as T | undefined);
}

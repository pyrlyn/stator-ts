// `b` annotates nothing, so what `a` sees comes from reading `b`'s bodies.
import { both, gen, Inferred, isString, later, num, promised, rec, str, thrower } from "./b";

const one: string = num();
const two: number = str();
const three: boolean = both(true);
const four: string = rec(1);
const five: string = thrower();
const six: string = promised();

function narrows(x: unknown) {
	if (isString(x)) return x.toFixed();
}

const inferred = new Inferred();
const seven: string = inferred.x;
const eight: number = inferred.y;

for (const n of gen()) {
	const nine: string = n;
}

const ten: string = later;

export { one, two, three, four, five, six, seven, eight, ten, narrows };

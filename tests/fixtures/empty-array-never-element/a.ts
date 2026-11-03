// Under strict checks a bare `[]` holds `never`: nothing can be pushed into what it infers to.
const a = [];
a.push(1);
const b = [].concat([1]);
function f<T>(x: T[]): T { return x[0]!; }
const c: string = f([]);
const d = [[]];
d[0].push(1);

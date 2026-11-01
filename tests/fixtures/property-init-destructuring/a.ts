declare function pair(): [string, number];
declare function resolvers(): { promise: Promise<void>; resolve: () => void; rest: string[] };

class FromTuple {
	private first: string;
	private second: number;
	constructor() {
		[this.first, this.second] = pair();
	}
}
class FromObject {
	readonly promise: Promise<void>;
	private done: () => void;
	private missing: number;
	constructor() {
		({ promise: this.promise, resolve: this.done } = resolvers());
	}
}
class FromRest {
	private head: string;
	private tail: number[];
	constructor() {
		[this.head, ...this.tail] = pair() as unknown as [string, ...number[]];
	}
}
class FromObjectRest {
	private rest: { rest: string[] };
	constructor() {
		({ ...this.rest } = resolvers());
	}
}

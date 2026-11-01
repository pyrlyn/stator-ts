// A property with no type and no initializer takes its type from the constructor's assignments.
declare function count<T>(items: readonly T[], test: (x: T) => boolean): number;
declare function box<T>(owner: object, make: () => T): { get(): T };

class Model {
	readonly ranges;
	readonly label;
	readonly maybe;
	readonly self;

	constructor(flag: boolean) {
		this.ranges = box<{ open: boolean }[]>(this, () => []);
		this.label = 'text';
		if (flag) {
			this.maybe = 1;
		} else {
			this.maybe = 'one';
		}
		this.self = this;
	}

	get open(): number {
		return count(this.ranges.get(), r => r.open);
	}

	lengthOfLabel(): number {
		return this.label.length;
	}

	both(): string {
		return typeof this.maybe === 'number' ? this.maybe.toFixed() : this.maybe.trim();
	}
}

export const shown: number = new Model(true).open;

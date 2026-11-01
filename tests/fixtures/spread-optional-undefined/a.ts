interface Inspect<T> {
	readonly value?: T;
	readonly overrides?: { readonly ids: string[]; readonly value: T }[];
}
interface Value<T> {
	readonly value?: T;
	readonly memory?: Inspect<T>;
}
class Config {
	inspect<T>(key: string): Value<T> { return null!; }
}
export const service = new class extends Config {
	override inspect<T>(key: string) {
		const value = super.inspect<T>(key);
		return { ...value };
	}
};

// A lone optional is copied as is, `undefined` included.
declare const lone: { a?: number };
const copied = { ...lone };
const stillOptional: { a?: number } = copied;
const required: { a: number } = copied;

// Over a known property it adds to that property's type.
declare const over: { a?: string };
const merged = { a: 1, ...over };
const mergedOk: number | string = merged.a;
const mergedBad: number = merged.a;
const optionalLeft = { ...lone, ...over };
const leftOk: number | string | undefined = optionalLeft.a;
const leftBad: number | string = optionalLeft.a;

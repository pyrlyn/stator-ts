interface Item { type?: 'x'; label: string; id?: string }
interface Sep { type: 'separator'; label?: string }
type Input<T> = T | Sep;
interface Opts<T> { activeItem?: Promise<T> | T; canPickMany?: boolean }
interface Picker {
	pick<T extends Item>(picks: Promise<Input<T>[]> | Input<T>[], options?: Opts<T> & { canPickMany: true }): Promise<T[] | undefined>;
	pick<T extends Item>(picks: Promise<Input<T>[]> | Input<T>[], options?: Opts<T> & { canPickMany: false }): Promise<T | undefined>;
	pick<T extends Item>(picks: Promise<Input<T>[]> | Input<T>[], options?: Omit<Opts<T>, 'canPickMany'>): Promise<T | undefined>;
}
declare const q: Picker;
q.pick = async (picks, options) => {
	const items = (await picks).filter(item => item.type !== 'separator');
	const a: number = items;
	const b: number = options;
	return items.find(item => item.label === 'a');
};
const r: Picker = {
	pick: async (picks, options) => {
		const items = await picks;
		const pickItems = items.filter(item => item.type !== 'separator');
		return pickItems.find(item => item.label === 'b');
	}
};
interface Two { f<T>(a: T): T; f<U extends string>(a: U, b: number): U }
const t: Two = { f: (a, b) => a };
interface Three { f(a: string): void; f(a: number, b: string): void }
const u: Three = { f: (a, b) => { const n: boolean = a; const m: boolean = b; } };

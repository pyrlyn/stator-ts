// A candidate is widened before it meets the constraint, so a literal may have more members.
interface Item { label: string; description?: string }
interface Sep { type: 'separator'; label?: string }
declare function one<T extends Item>(x: T): T;
declare function three<T extends Item>(x: T[]): T;
declare function four<T extends Item>(x: T | Sep): T;
declare function five<T extends Item>(x: (T | Sep)[]): T;
declare function six<T extends Item>(x: (T | undefined)[]): T;
declare function pick<T extends Item>(p: Promise<(T | Sep)[]> | (T | Sep)[]): Promise<T | undefined>;

const n1: number = one({ label: 'x', result: false });
const n3: number = three([{ label: 'x', result: false }]);
const n4: number = four({ label: 'x', result: false });
const n5: number = five([{ label: 'x', result: false }]);
const n6: number = six([{ label: 'x', result: false }]);

async function f() {
	const picked = await pick([{ label: 'a', result: false }, { label: 'b', result: true }]);
	const yes: boolean | undefined = picked?.result;
	const no: string | undefined = picked?.result;
	return yes ?? no;
}

// Missing what the constraint asks for is still an error.
one({ result: false });

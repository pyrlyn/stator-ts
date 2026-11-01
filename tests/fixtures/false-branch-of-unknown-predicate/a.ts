declare const a: any[];
const r: Record<string, unknown> = a;
declare function isObject(obj: unknown): obj is Object;
declare function isString(s: unknown): s is string;
const pe = (obj: Record<string, unknown>, key: string | number, command?: boolean) => {
	const value = obj[key];
	if (isString(value)) {
		const s = value;
	} else if (isObject(value)) {
		for (const k in value) {
			if (value.hasOwnProperty(k)) {
				k === 'commands' ? pe(value as Record<string, unknown>, k, true) : pe(value as Record<string, unknown>, k, command);
			}
		}
	} else if (Array.isArray(value)) {
		for (let i = 0; i < (value as Array<unknown>).length; i++) {
			pe(value, i, command);
		}
	}
};

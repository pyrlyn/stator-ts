function notNull<T>(value: T) {
	if (value !== null) {
		const kept: T & ({} | undefined) = value;
		return kept;
	}
	return undefined;
}
function neither<T>(value: T) {
	if (value !== null && value !== undefined) {
		const kept: T & {} = value;
		return kept;
	}
	return undefined;
}
function loose<T>(value: T) {
	if (value != null) {
		const kept: T & {} = value;
		return kept;
	}
	return undefined;
}
function truthy<T>(value: T) {
	if (value) {
		const kept: T & {} = value;
		return kept;
	}
	return undefined;
}
function inUnion<T>(value: T | null) {
	if (value !== null) {
		const kept: T = value;
		return kept;
	}
	return undefined;
}
function inUnionBoth<T>(value: T | null | undefined): T | undefined {
	if (value === null) {
		return undefined;
	}
	return value;
}
function indexed<T, K extends keyof T>(source: T, key: K) {
	const value = source[key];
	if (value) {
		const kept: T[K] & {} = value;
		return kept;
	}
	return undefined;
}
function stillGeneric<T>(value: T) {
	if (value !== null) {
		const wrong: {} = value;
		return wrong;
	}
	return undefined;
}
function falsyBranch<T>(value: T) {
	if (!value) {
		const wrong: T & {} = value;
		return wrong;
	}
	return undefined;
}
function constrained<T extends string>(value: T & undefined) {
	const never: number = value;
	return never;
}
function coalesced<T>(value: T, existing: NonNullable<T> | undefined): NonNullable<T> | undefined {
	return value === undefined ? existing : value ?? undefined;
}

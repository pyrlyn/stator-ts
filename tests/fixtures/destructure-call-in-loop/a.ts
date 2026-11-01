// A destructured call has no flow of its own: walking one back through the loop would resolve the
// generic `asserts` below, which needs `owner` while it is still being typed.
declare function eq<T>(actual: unknown, expected: T): asserts actual is T;

function make() {
	const owner = { children: ['a'] };
	return { owner };
}

for (const p of [1, 2]) {
	const { owner } = make();
	const names = () => Array.from(owner.children).map(c => c.length);
	const before = names();
	eq({ before, p }, { before: [1], p: 1 });
}

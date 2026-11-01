// A test on `(x.kind as string)` is about the cast, so it leaves `x` alone.
type R = { method: 'a'; id: number } | { method: 'b'; id: number };
declare const msg: R;
const other = 'c';
if ((msg.method as string) === other) {
	msg.id;
}

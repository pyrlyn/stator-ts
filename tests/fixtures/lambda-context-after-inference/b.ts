export {};
interface AO<S> { [p: string]: (s: S) => S }
interface O<S, A> { state?: S; actions: string | A }
declare function app<S, A extends AO<S>>(o: O<S, A>): void;
app({ state: 100, actions: { foo: s => s } });
interface O2<S, A> { state?: S; actions: A }
declare function app2<S, A extends AO<S>>(o: O2<S, A>): void;
app2({ state: 100, actions: { foo: s => s } });
type AA<S> = ((s: S) => S)[];
declare function app3<S, A extends AA<S>>(o: O<S, A>): void;
app3({ state: 100, actions: [s => s] });
interface O3<S, A> { state?: S; view?: (s: S, a: A) => any; actions: string | A }
declare function app4<S, A extends AA<S>>(o: O3<S, A>): void;
app4({ state: 100, actions: [s => s], view: (s, a) => undefined as any });

// A reference that stays at its declared type never walks the back edge of a loop, so a later
// assertion call cannot pull in the variable that is still being resolved.
type N = { type: "a"; a: number } | { type: "b"; b: string };
interface Evt<T> {
  (listener: (e: T) => unknown): void;
}
interface Service {
  onEvent: Evt<N>;
}

declare function make(): Service;
declare function filter<T>(event: Evt<T>, f: (e: T) => boolean): Evt<T>;
declare function toPromise<T>(event: Evt<T>): Promise<T>;
declare const store: { add<T>(x: T): T };
declare const check: { same<T>(actual: unknown, expected: T): asserts actual is T };

export async function run() {
  for (const expected of ["a", "b"]) {
    const svc = store.add(make());
    const pending = toPromise(filter(svc.onEvent, n => n.type === "a"));
    const got = await pending;
    check.same({ kind: got.type }, { kind: expected });
  }
}

export function stillNarrows(x: string | number, list: number[]) {
  if (typeof x === "string") {
    for (const item of list) {
      const s: string = x;
      x = item;
      const n: number = s;
    }
  }
}

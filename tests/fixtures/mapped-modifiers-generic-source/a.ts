// `Pick` keeps `?` and `readonly` of its source even while that source still holds a type parameter.
interface Update<T> {
  readonly a?: T;
  readonly b?: number;
}
interface Options<T, F = void> extends Update<T> {
  readonly c?: F;
  readonly d?: T[];
  readonly e: string;
}
interface Partial1<T, F = void> extends Update<T>, Pick<Options<T, F>, Exclude<keyof Options<T, F>, "e">> {
  readonly x?: string;
}

export function open<T, F>(o: Partial1<T, F> = {}) {
  return o;
}

export function closed(o: Partial1<string, number> = {}) {
  return o;
}

interface Bare<T> extends Pick<Options<T>, "a" | "d"> {}

export function bare<T>(o: Bare<T> = {}) {
  return o;
}

interface Required1<T> extends Pick<Options<T>, "a" | "e"> {}

export function required<T>(o: Required1<T> = {}) {
  return o;
}

export function frozen<T>(o: Bare<T>, v: T) {
  o.a = v;
}

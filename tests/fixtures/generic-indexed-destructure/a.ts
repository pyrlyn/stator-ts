function objects<T extends { a: { b: number } }>(x: T['a']) {
  const { b } = x;
  const s: string = b;
  return s;
}

function arrays<T extends { list: number[] }>(x: T['list']) {
  const [first] = x;
  const s: string = first;
  return s;
}

function maybe<T extends { a?: { b: number } }>(x: T['a']) {
  const { b } = x;
  return b;
}

type Extended<T> = { [K in keyof T]: T[K] & { mode?: string; action?: string } };
type Service<T> = { [K in keyof T]: T[K] & { id?: string } };

function mapped<T>(all: Extended<T> & Service<T>) {
  Object.keys(all).forEach((key) => {
    const method = (all)[key as keyof T];
    const { mode, action, id } = method;
    return [mode, action, id];
  });
}

export { objects, arrays, maybe, mapped };

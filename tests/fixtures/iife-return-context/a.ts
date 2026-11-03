const f = (): (x: number) => number => (() => (x) => x)();
const g: (s: string) => void = (function () { return (s) => { const n: number = s; }; })();
async function h(): Promise<(x: string) => void> {
  return (async () => (x) => { const n: number = x; })();
}
class C {
  constructor() {
    return { a: 1 };
  }
}
class D {
  v = 1;
  constructor() {
    return { v: "a" };
  }
}

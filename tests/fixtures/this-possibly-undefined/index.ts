class Box {
  value?: { size: number };
  read() {
    return this.value.size;
  }
  guarded(this: { n: number } | undefined) {
    return this.n;
  }
}
export { Box };

function f(this: { a?: { b?: string } }) {
  const n: typeof this.a = undefined;
  return this.a.b;
}
export { f };

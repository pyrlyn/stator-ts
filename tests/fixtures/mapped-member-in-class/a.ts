enum S { A = -1, B = 0 }
export class L {
  a: { [K in "x" | "y"]: number } = null!;
  private readonly e: { [K in S]?: number[] } = {};
  u(k: "x" | "y", s: S) {
    const a1: string = this.a[k];
    const a2: string = this.e[s];
    return this.e[s] ??= [1];
  }
  g(s: S) {
    const r: string = this.u("x", s);
    return r;
  }
}
export class M<T> {
  v: { [K in keyof T]: number } = null!;
  w: { [K in keyof this]: number } = null!;
  u<K extends keyof T>(k: K) {
    return this.v[k];
  }
}

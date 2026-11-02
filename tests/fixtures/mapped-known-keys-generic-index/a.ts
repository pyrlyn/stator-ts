type K = 'a' | 'b';
interface F<T extends K> { t: T; run(): void }
class S {
  private readonly fs: { [T in K]?: F<T>[] } = {};
  reg<T extends K>(type: T, f: F<T>) {
    this.fs[type] ??= [];
    this.fs[type]!.push(f);
    this.fs[type]?.indexOf(f);
    this.fs[type].length;
    this.fs[type]!.nope;
    this.fs[type]?.nope;
    const present = this.fs[type]!;
    present.length;
    present.nope;
  }
}

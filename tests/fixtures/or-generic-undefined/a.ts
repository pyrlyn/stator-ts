type K = 'a' | 'b';
interface SF<T extends K> { s(x: T): boolean }
class X {
  private fs: { [T in K]?: SF<T>[] } = {};
  g<T extends K>(m: { type: T }): SF<T> | undefined {
    const factories = this.fs[m.type] || [];
    return factories.find(f => f.s(m.type));
  }
  h<T extends K>(m: { type: T }) {
    const n: number = this.fs[m.type] || [];
  }
}
function v<T extends string | undefined>(x: T) {
  const s: string = x || 'd';
  const n: number = x || 'd';
}

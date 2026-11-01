interface Tree<T> { value: T; kids: Tree<T>[] }
declare const ta: Tree<'a'>;
const t1: Tree<string> = ta;
const t2: Tree<number> = ta;
interface Stream<T> { head: T; tail(): Stream<T>; map<U>(f: (x: T) => U): Stream<U> }
declare const sa: Stream<'a'>;
const s1: Stream<string> = sa;
const s2: Stream<number> = sa;
declare const deep: string[][][][][];
const n1: readonly (readonly (readonly string[])[])[][] = deep;
const n2: number[][][][][] = deep;

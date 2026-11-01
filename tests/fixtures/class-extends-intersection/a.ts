declare function mock<T>(): new () => T;
interface W { closed: boolean; open(): void; }
interface H { open(url: string): number; other: string; }
class Y extends mock<W & H>() {}
class Z extends mock<W & typeof globalThis>() {}
class O extends mock<W & H>() { override closed = false; }
declare function useH(x: H): void;
declare function useG(x: typeof globalThis): void;
useH(new Y());
useG(new Z());
useH(new O());
export const a: boolean = new Y().open;
export const b: number = new Y().open('x');

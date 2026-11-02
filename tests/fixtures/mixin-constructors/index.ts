type Constructor<T> = new (...args: any[]) => T;
class Base { constructor(public x: number) {} }
function Tagged<T extends Constructor<{}>>(superClass: T) {
    class C extends superClass { tag = "t"; }
    return C;
}
const Thing1 = Tagged(Base);
const t = new Thing1(1);
const a: string = t.x;
const b: number = t.tag;
type I = typeof Thing1;
declare const m: Constructor<{ q: 1 }> & Constructor<{ r: 2 }>;
const n = new m();
const c: string = n.q;

class MyBaseClass<T> { baseProperty!: string; constructor(value: T) {} }
interface MyMixin { mixinProperty: string; }
declare function MyMixin<T extends Constructor<MyBaseClass<any>>>(base: T): T & Constructor<MyMixin>;
class MyExtendedClass extends MyMixin(MyBaseClass)<string> { extendedClassProperty!: number; }
const i = new MyExtendedClass("s");
const j = new MyExtendedClass(1);
const p: number = i.mixinProperty;

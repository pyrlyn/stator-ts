const f = <T>(x: T) => ({ value: x });
const g: <U>(x: U) => { value: U } = f;
const f2 = <T>(x: T) => ({ value: x as T | undefined });
const g2: <U>(x: U) => { value?: U } = f2;
class A { m<T>(x: T): { value?: T } { return {}; } }
class B extends A { override m<T>(x: T) { return { value: x }; } }
class B2 extends A { override m<T>(x: T) { return { value: x as T | undefined }; } }
class B3 extends A { override m<T>(x: T, y?: number) { return { value: x as T | undefined }; } }
class C { m<T>(x: T, y?: number): { value?: T } { return {}; } }
class D extends C { override m<T>(x: T) { return { value: x as T | undefined }; } }
class D2 extends C { override m<T>(x: T): { value: T | undefined } { return { value: x as T | undefined }; } }
class E_ { m<T>(key: string, y?: number): { value?: T } { return {}; } }
class F extends E_ { override m<T>(key: string): { value?: T } { return {}; } }
class G extends E_ { override m<T>(key: string) { return {} as { value?: T }; } }
class H extends E_ { override m<T>(key: string) { return { value: undefined as T | undefined }; } }

// A spread brings the method's own parameter along, and the override still has to match.
interface V<T> { readonly a?: T; readonly value?: T; readonly policy?: { value?: T } }
class Svc { inspect<T>(key: string, over?: { x: number }): V<T> { return {}; } }
class Spreads extends Svc {
	override inspect<T>(key: string) {
		const i = super.inspect<T>(key);
		return { ...i, a: key === 'x' ? i.value : undefined };
	}
}

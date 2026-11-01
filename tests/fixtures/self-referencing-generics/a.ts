export abstract class BaseR<TSelf extends BaseR<TSelf>> { abstract self(): TSelf; r = 1; }
export abstract class BaseE<T extends BaseR<T> = BaseR<any>, TEdit extends BaseE<T, TEdit> = BaseE<T, any>> {
	constructor(public readonly replacements: readonly T[]) { }
	abstract create(x: readonly T[]): TEdit;
	mine(): TEdit { return this.create(this.replacements); }
}
export abstract class BaseSR<T extends BaseSR<T> = BaseSR<any>> extends BaseR<T> { s = ''; }
export abstract class BaseSE<T extends BaseSR<T> = BaseSR<any>, TEdit extends BaseSE<T, TEdit> = BaseSE<any, any>> extends BaseE<T, TEdit> {
	rebase(base: TEdit) { return base.replacements.length; }
}
export class SE extends BaseSE<SR, SE> {
	override create(x: readonly SR[]): SE { return new SE(x); }
	static d(): SE { return new SE([]); }
	tryRebase(o: SE) { return o; }
}
export class SR extends BaseSR<SR> { override self() { return this; } }
export const a1 = SE.d().replacements[0];
export function rb(x: SE, y: SE) { return x.tryRebase(y).replacements.length; }

export interface IDisp { dispose(): void; }
declare class Store { add<T extends IDisp | undefined>(o: T): T; }
export class Act<T> implements IDisp { constructor(public x: T, o: { a: number }) { } dispose() { } foo() { return 1; } }
interface I2 { createInstance<Ctor extends new (...args: any[]) => unknown, R extends InstanceType<Ctor>>(ctor: Ctor, ...args: ConstructorParameters<Ctor>): R; }
export function ce<T>(st: Store, i: I2, x: T) {
	const list = st.add(i.createInstance(Act<T>, x, { a: 1 }));
	return list.foo();
}
export function harness() {
	let allowed = true;
	const r = { get val() { return 1; }, set allowed(v: boolean) { allowed = v; }, get both() { return allowed; }, set both(b: boolean) { allowed = b; } };
	r.allowed = false;
	r.both = true;
	return r.val;
}
type U = { kind: string; a: 1 } | { pref: string[] };
export function inn(args?: U) { if (args) { if ('kind' in args) { return args.kind; } } return 0; }
export declare function hasKey<T extends object, TKeys extends MakeOpt<T>>(x: T, key: TKeys): x is FilterType<T, { [K in KeysOf<T> & keyof TKeys]: unknown }>;
type KeysOf<T> = T extends T ? keyof T : never;
type MakeOpt<T> = { [K in KeysOf<T>]?: true };
type FilterType<T, TTest> = T extends TTest ? T : never;
type Msg = { method: string; params: number } | { id: number; result: string } | { id: number; error: string };
export function hk(m: Msg) { if (hasKey(m, { method: true }) && m.method === 'x') { return m.params; } if (hasKey(m, { result: true })) { return m.result; } return 0; }

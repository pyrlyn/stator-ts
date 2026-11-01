interface CP<T> extends Promise<T> { cancel(): void }
function a1(): CP<void> | Promise<void> {
	return new Promise((resolve, reject) => { const p: number = resolve; resolve(); });
}
function a2(): CP<void> {
	return new Promise((resolve, reject) => { const p: number = resolve; resolve(); }) as any;
}
const b1: CP<void> | Promise<void> = new Promise(r => { const p: number = r; });
const b2: CP<number> = new Promise(r => { const p: number = r; });
const b3: Promise<number> | CP<void> = new Promise(r => { const p: number = r; });
declare function id<T>(x: Promise<T>): T;
declare const cv: CP<void>;
const d1: number = id(cv);
declare const cu: CP<void> | Promise<string>;
const d2: number = id(cu);

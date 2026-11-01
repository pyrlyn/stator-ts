interface Box<T> { value: T; kind: 'box' }
interface Other { name: string; size: number }
declare function unbox<T>(x: Box<T> | T): T;
declare const other: Other;
declare const box: Box<string>;
const a: Other = unbox(other);
const b: string = unbox(box);
const c: number = unbox(other);

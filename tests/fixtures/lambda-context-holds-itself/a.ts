type TakeString = (s: string) => any;
declare function mapped4<T>(obj: T & { [P in keyof T]: TakeString }): void;
mapped4({ foo: s => 42 });

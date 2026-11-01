declare function one<T extends number>(x: T): T;
one<string>("a");
one<number>(1);
declare function pair<T extends string>(x: T): T;
declare function pair<T extends number>(x: T, y: T): T;
pair<boolean>(true);
export {};

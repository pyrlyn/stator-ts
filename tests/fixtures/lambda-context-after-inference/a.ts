export {};
interface Id<T> { _t: T }
interface Rule { id: string; kind: "session" | "file" }
interface Svc { rule(u: string): Rule | undefined; }
declare const S: Id<Svc>;
declare function s1<T>(id: Id<T>, o: Partial<T>): T;
s1(S, { rule: () => ({ id: "a", kind: "session" }) });
declare function s2<T>(id: Id<T>, o: Partial<NoInfer<T>>): T;
s2(S, { rule: () => ({ id: "a", kind: "session" }) });
declare function s3<T>(id: Id<T>, o: Partial<T> | Function): T;
s3(S, { rule: () => ({ id: "a", kind: "session" }) });
declare function s4<T>(id: Id<T>, o: T | Function): T;
s4(S, { rule: () => ({ id: "a", kind: "session" }) });
declare function s5<T>(id: Id<T>, o: T): T;
s5(S, { rule: () => ({ id: "a", kind: "session" }) });
declare function s6(o: Partial<Svc> | Function): void;
s6({ rule: () => ({ id: "a", kind: "session" }) });

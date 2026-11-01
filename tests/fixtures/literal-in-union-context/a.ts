interface Opt { postfix: string }
declare function write(o: { atomic?: Opt | false }): void;
declare const flag: boolean;
write({ atomic: flag ? { postfix: "a" } : false });
interface I { state_reason: "completed" | "not_planned" | null }
const v: I = { state_reason: flag ? "completed" : null };
declare function arr(x: I[]): void;
arr([{ state_reason: flag ? "completed" : null }]);
type Step = { missingTarget: { kind: "skip" } | { kind: "wait"; timeoutMs: number } };
export {};

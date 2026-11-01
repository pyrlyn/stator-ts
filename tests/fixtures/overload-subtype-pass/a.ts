declare const untyped: any;
function toExpression(...patterns: string[]): Record<string, boolean> | undefined {
  return patterns.length
    ? patterns.reduce((glob, cur) => { glob[cur] = true; return glob; }, untyped)
    : undefined;
}
declare function pick(a: string): string;
declare function pick(a: any): number;
const n: number = pick(untyped);
export { toExpression, n };

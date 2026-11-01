// A spread gives its operand no context, so the inner literal widens and the lambda stays untyped.
declare const c: boolean;
const a: ({ k: 'a' })[] = [...(c ? [{ k: 'a' }] : [])];
const d: ((x: number) => void)[] = [...[(x) => { return; }]];
const e: ({ k: 'a' })[] = [{ k: 'a' }];
export { a, d, e };

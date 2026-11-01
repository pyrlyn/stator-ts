declare function parse(l: string): [string, string] | [null, null];
function f(l: string, m: Map<string, string>) {
  const [key, value] = parse(l);
  if (key) { m.set(key, value); }
  m.set(value, value);
}
type E = ['a', number] | ['b', string];
function g(e: E) {
  const [k, v] = e;
  if (k === 'a') { const n: number = v; } else { const s: string = v; const b: boolean = v; }
}

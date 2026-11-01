for (const [name, dc, peer] of ([['a', 'b'], ['c', 'd']] as const).flatMap(row => [true, false].map(c => [...row, c] as const))) {
  const x: string = dc;
  const y: boolean = peer;
  const z: number = peer;
}
declare const row: ['a', 'b'] | ['c'];
const t = [...row, 1] as const;
const u: readonly ['a', 'b', 1] | readonly ['c', 1] = t;
const v: readonly ['a', 1] = t;

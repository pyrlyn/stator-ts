function a(v: {}) {
  if (v === 'x') { const s: 'x' = v; }
  if (v === 1) { const n: 1 = v; }
}
function b(v: unknown, o: { p: number }) {
  if (v === o) { const q: { p: number } = v; }
  if (v === 'x') { const s: number = v; }
  if (v == 'y') { const s: string = v; }
}
function c(value: unknown) {
  const status = value === undefined ? 'ready' : value;
  if (status !== 'ready' && status !== 'failed') { return undefined; }
  const s: 'ready' | 'failed' = status;
  return s;
}

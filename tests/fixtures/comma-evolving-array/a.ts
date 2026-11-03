function commas() {
  let x;
  (x = [], x).push(5);
  (x.push('hello'), x).push(true);
  ((x))[3] = { a: 1 };
  return x;
}
const r: number = commas();

function assigned() {
  let y;
  (y = []).push(1);
  return y;
}
const s: number = assigned();

export { r, s };

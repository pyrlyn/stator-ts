declare function get(): string;
export function f() {
  let s: string;
  try {
    s = get();
  } catch {
    console.log("failed");
  }
  return { stop() { return s.length; } };
}
export function g() {
  let s: string;
  return () => s.length;
}
export function h(on: boolean) {
  let s: string;
  if (on) s = get();
  [1].forEach(() => s.length);
  return s;
}

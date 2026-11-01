function f<T extends string | undefined>(x: T, g: (s: string) => void) {
  if (x) {
    g(x);
    x.length;
  }
  x.length;
}
interface A { k: 'a'; a: number }
interface B { k: 'b'; b: string }
function h<T extends A | B>(x: T) {
  if (x.k === 'a') {
    x.a;
    x.b;
  } else {
    x.b;
  }
}
function e<T extends object | null>(o: T, k: keyof T) {
  if (o) { o[k]; }
}

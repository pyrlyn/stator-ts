function f<T>(x: T & string, y: T & object, z: T & { a: number }) {
  x.length;
  y.toString();
  z.a;
  x.nope;
  z.b;
}

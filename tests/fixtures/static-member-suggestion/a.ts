class C<T> {
  static s = 1;
  i = 2;
}

C.i;
new C<number>().s;
new C().missing;
export {};

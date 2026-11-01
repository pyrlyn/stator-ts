export class C<T> extends E<T> {}
export class D<T> extends C<T> {}
export class E<T> extends D<T> {}
new C<string>().missing;

class C {
  constructor() {}
  constructor(a: number) {}
}
class D {
  constructor(a: string);
  constructor(a: number);
  constructor(a: any) {}
}
new D(true);

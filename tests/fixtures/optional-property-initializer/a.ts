class M { a = 1 }
export class C {
  private m?: M = undefined;
  p?: M = undefined;
  q?: number = undefined;
  r?: number = "no";
  use() { return this.m; }
}

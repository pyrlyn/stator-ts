class Base {
  static made = 1;
  static make(): number {
    return 2;
  }
  own(): string {
    return 'own';
  }
}

export class Derived extends Base {
  static viaSuper(): number {
    return super.make() + super.made;
  }
  static wrong(): string {
    return super.own();
  }
  instance(): string {
    return super.make();
  }
}

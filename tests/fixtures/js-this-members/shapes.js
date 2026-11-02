export class Point {
  constructor(x) {
    this.x = 0;
    this.label = "origin";
    if (x) this.x = x;
  }
  move() {
    this.moved = true;
    this.x = "far";
    this.history = [];
    this.history.push(1);
    this.name = this.name + "!";
    this.cleared = null;
  }
  bound() {
    this.bound = this.bound.bind(this);
  }
  static make() {
    this.count = 1;
    return new Point(1);
  }
}

export class Named extends Point {
  rename() {
    this.label = 1;
    this.label = this.label + 1;
  }
}

const p = new Point(2);
p.label.toUpperCase();
p.moved.toFixed();
p.missing;
Point.count.toFixed();
new Named(1).label.toFixed();

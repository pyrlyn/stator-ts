enum State { A, B, C }
declare const events: { t: number }[];
function f() {
  let s = State.A;
  for (const e of events) {
    switch (e.t) {
      case 0:
        if (s === State.B) { s = State.C; }
        break;
      case 1:
        s = State.B;
        break;
      case 2:
        if (s === State.C) { s = State.A; }
        break;
    }
  }
  const out: string = s;
  return s;
}

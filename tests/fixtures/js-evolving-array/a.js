function grow() {
  const a = [];
  a.push(1);
  a.push('two');
  return a;
}
const grown = grow();

function index() {
  const a = [];
  a[0] = 1;
  const k = 'key';
  a[k] = true;
  return a;
}
const indexed = index();

function loops(n) {
  const a = [];
  for (let i = 0; i < n; i++) a.push(i);
  return a;
}
const looped = loops(1);

function branches(c) {
  const a = [];
  if (c) a.push(1);
  else a.push('s');
  return a;
}
const branched = branches(true);

function untouched() {
  const a = [];
  return a;
}

function closure() {
  const a = [];
  a.push(1);
  return () => a;
}

function late() {
  let x;
  x = [];
  x.push(true);
  return x;
}
const lated = late();

function reassigned() {
  let x = [];
  x.push(1);
  x = [true];
  return x;
}
const redone = reassigned();

function lengths() {
  const a = [];
  const before = a.length;
  a.push('a');
  a.unshift(2);
  return [before, a];
}
const lens = lengths();

function spreadInto(xs) {
  const a = [];
  a.push(...xs);
  a.push({ k: 1 });
  return a;
}
const spreaded = spreadInto([]);

function narrowed(c) {
  let x;
  if (c) {
    x = [];
    x.push(5);
    x.push('hello');
  } else {
    x = [true];
  }
  return x;
}
const narrow = narrowed(true);

function wrongTarget() {
  let x = [];
  x = 1;
  return x;
}

const box = [];
box.push(() => 1);
const called = box.map((f) => f().toFixed());

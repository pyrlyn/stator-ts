let n;
const before = n;
n = 2;
const after = n.toFixed();
n = 'text';
const later = n.length;
const wrong = n.toFixed();

let m = null;
m = 1;
const mm = m.toFixed();
function inner() {
  return m;
}

var v;
for (v of [1, 2, 3]) v.toFixed();
const stale = v;

function loop(iter) {
  var key;
  for (key of iter.keys()) {
    if (key === 1) return key;
  }
}

function hoisted() {
  console.log(late);
  var late = 1;
  return late;
}

interface G { matches: string[]; groups: { a: string }[]; rule: number | null }
function f(n: number) {
  let g: G | null = null;
  let p = 0;
  let force = true;
  while (force || p < n) {
    let m: string[] | null = null;
    let rule: number | null = null;
    if (g) {
      m = g.matches;
      g.groups.shift();
      rule = g.rule;
      if (g.groups.length === 0) { g = null; }
    } else {
      if (!force && p >= n) { return; }
      force = false;
      m = ['a'];
      rule = 1;
    }
    if (!m) { continue; }
    if (Array.isArray(m)) {
      if (g && g.groups.length > 0) { throw 1; }
      g = { matches: m, rule: rule, groups: [] };
      g.groups[0] = { a: 'b' };
      continue;
    }
    p++;
  }
}

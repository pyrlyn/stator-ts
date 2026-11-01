// Preloaded into every test process. Plain JS, because it runs before anything is compiled
// and has to behave the same on Node and Bun.
import { isDeepStrictEqual, inspect } from 'node:util';

const nameFilter = process.env.STATOR_TS_TEST_NAME ? new RegExp(process.env.STATOR_TS_TEST_NAME) : null;
const defaultTimeout = Number(process.env.STATOR_TS_TEST_TIMEOUT || 5000);

const newSuite = (name, parent, mode) => ({
  name, parent, mode, tests: [], suites: [],
  beforeAll: [], afterAll: [], beforeEach: [], afterEach: [],
});
const root = newSuite('', null, 'run');
let current = root;
let hasOnly = false;

function addSuite(name, fn, mode) {
  const s = newSuite(name, current, mode === 'run' ? current.mode : mode);
  if (mode === 'only') hasOnly = true;
  current.suites.push(s);
  const saved = current;
  current = s;
  try {
    const r = fn();
    if (r && typeof r.then === 'function') throw new Error('describe() callback must not be async');
  } finally {
    current = saved;
  }
}

function addTest(name, fn, mode, timeout) {
  if (mode === 'only') hasOnly = true;
  current.tests.push({ name, fn, mode: mode === 'run' ? current.mode : mode, timeout });
}

const describe = (name, fn) => addSuite(name, fn, 'run');
describe.skip = (name, fn) => addSuite(name, fn, 'skip');
describe.only = (name, fn) => addSuite(name, fn, 'only');

const test = (name, fn, timeout) => addTest(name, fn, 'run', timeout);
test.skip = (name, fn) => addTest(name, fn, 'skip');
test.only = (name, fn, timeout) => addTest(name, fn, 'only', timeout);
test.todo = (name) => addTest(name, null, 'skip');
test.each = (rows) => (name, fn) => {
  for (const row of rows) {
    const args = Array.isArray(row) ? row : [row];
    addTest(name.replace(/%[sdiofj]/g, () => String(args[0])), () => fn(...args), 'run');
  }
};

const hook = (key) => (fn) => { current[key].push(fn); };

const show = (v) => inspect(v, { depth: 6, breakLength: 80 });

function subset(actual, expected) {
  if (expected === null || typeof expected !== 'object') return Object.is(actual, expected);
  if (actual === null || typeof actual !== 'object') return false;
  return Object.keys(expected).every((k) => subset(actual[k], expected[k]));
}

function makeExpect(actual, negated, wrap) {
  const check = (pass, message) => {
    if (pass === negated) throw new Error(`expect${negated ? '.not' : ''}: ${message}`);
  };
  const matchers = {
    toBe: (e) => check(Object.is(actual, e), `${show(actual)} toBe ${show(e)}`),
    toEqual: (e) => check(isDeepStrictEqual(actual, e), `${show(actual)} toEqual ${show(e)}`),
    toStrictEqual: (e) => check(isDeepStrictEqual(actual, e), `${show(actual)} toStrictEqual ${show(e)}`),
    toBeTruthy: () => check(!!actual, `${show(actual)} toBeTruthy`),
    toBeFalsy: () => check(!actual, `${show(actual)} toBeFalsy`),
    toBeNull: () => check(actual === null, `${show(actual)} toBeNull`),
    toBeUndefined: () => check(actual === undefined, `${show(actual)} toBeUndefined`),
    toBeDefined: () => check(actual !== undefined, `${show(actual)} toBeDefined`),
    toBeNaN: () => check(Number.isNaN(actual), `${show(actual)} toBeNaN`),
    toBeGreaterThan: (e) => check(actual > e, `${show(actual)} toBeGreaterThan ${show(e)}`),
    toBeGreaterThanOrEqual: (e) => check(actual >= e, `${show(actual)} toBeGreaterThanOrEqual ${show(e)}`),
    toBeLessThan: (e) => check(actual < e, `${show(actual)} toBeLessThan ${show(e)}`),
    toBeLessThanOrEqual: (e) => check(actual <= e, `${show(actual)} toBeLessThanOrEqual ${show(e)}`),
    toBeCloseTo: (e, digits = 2) => check(Math.abs(actual - e) < 10 ** -digits / 2, `${show(actual)} toBeCloseTo ${show(e)}`),
    toBeInstanceOf: (e) => check(actual instanceof e, `${show(actual)} toBeInstanceOf ${e?.name}`),
    toHaveLength: (e) => check(actual?.length === e, `${show(actual)} toHaveLength ${e}`),
    toHaveProperty: (k, ...v) => {
      const got = String(k).split('.').reduce((o, p) => (o == null ? undefined : o[p]), actual);
      check(got !== undefined && (v.length === 0 || isDeepStrictEqual(got, v[0])), `${show(actual)} toHaveProperty ${k}`);
    },
    toContain: (e) => check(typeof actual === 'string' ? actual.includes(e) : [...actual].includes(e), `${show(actual)} toContain ${show(e)}`),
    toContainEqual: (e) => check([...actual].some((x) => isDeepStrictEqual(x, e)), `${show(actual)} toContainEqual ${show(e)}`),
    toMatch: (e) => check(e instanceof RegExp ? e.test(actual) : String(actual).includes(e), `${show(actual)} toMatch ${show(e)}`),
    toMatchObject: (e) => check(subset(actual, e), `${show(actual)} toMatchObject ${show(e)}`),
    toThrow: (e) => {
      let thrown;
      let threw = false;
      if (wrap === 'rejects') { thrown = actual; threw = true; }
      else { try { actual(); } catch (x) { threw = true; thrown = x; } }
      const message = thrown?.message ?? String(thrown);
      const ok = threw && (e === undefined || (e instanceof RegExp ? e.test(message)
        : typeof e === 'string' ? message.includes(e) : thrown instanceof e));
      check(ok, `function toThrow ${show(e)}, threw ${threw ? show(thrown) : 'nothing'}`);
    },
  };
  return matchers;
}

function expect(actual) {
  const out = makeExpect(actual, false);
  out.not = makeExpect(actual, true);
  const lift = (settle) => (negated) => new Proxy({}, {
    get: (_, key) => async (...args) => {
      const m = makeExpect(await settle(), negated, settle.wrap);
      return m[key](...args);
    },
  });
  const resolves = async () => actual;
  const rejects = async () => {
    let value;
    try { value = await actual; } catch (e) { return e; }
    throw new Error(`expected a rejection, resolved with ${show(value)}`);
  };
  rejects.wrap = 'rejects';
  out.resolves = lift(resolves)(false);
  out.rejects = lift(rejects)(false);
  return out;
}

function withTimeout(fn, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms} ms`)), ms);
    Promise.resolve().then(fn).then(resolve, reject).finally(() => clearTimeout(timer));
  });
}

const counts = { passed: 0, failed: 0, skipped: 0 };

function report(name, err) {
  counts.failed += 1;
  console.error(`  ✗ ${name}\n    ${String(err?.stack ?? err).replaceAll('\n', '\n    ')}`);
}

const chain = (s) => (s ? [...chain(s.parent), s] : []);
const fullName = (s, t) => [...chain(s).map((x) => x.name).filter(Boolean), t.name].join(' ');

function selected(s, t) {
  if (hasOnly && t.mode !== 'only' && !chain(s).some((x) => x.mode === 'only')) return false;
  return !nameFilter || nameFilter.test(fullName(s, t));
}

const anyRunnable = (s) => s.tests.some((t) => t.mode !== 'skip' && selected(s, t)) || s.suites.some(anyRunnable);

async function runTest(s, t) {
  const name = fullName(s, t);
  const ms = t.timeout ?? defaultTimeout;
  try {
    for (const x of chain(s)) for (const h of x.beforeEach) await withTimeout(h, ms, 'beforeEach');
    await withTimeout(t.fn, ms, name);
    counts.passed += 1;
  } catch (e) {
    report(name, e);
  }
  for (const x of chain(s).reverse()) {
    for (const h of x.afterEach) {
      try { await withTimeout(h, ms, 'afterEach'); } catch (e) { report(`${name} (afterEach)`, e); }
    }
  }
}

async function runSuite(s) {
  if (!anyRunnable(s)) {
    const skip = (x) => { counts.skipped += x.tests.length; x.suites.forEach(skip); };
    skip(s);
    return;
  }
  try {
    for (const h of s.beforeAll) await withTimeout(h, defaultTimeout, 'beforeAll');
  } catch (e) {
    report(`${s.name || 'file'} (beforeAll)`, e);
    return;
  }
  for (const t of s.tests) {
    if (t.mode === 'skip' || !selected(s, t)) counts.skipped += 1;
    else await runTest(s, t);
  }
  for (const c of s.suites) await runSuite(c);
  for (const h of s.afterAll) {
    try { await withTimeout(h, defaultTimeout, 'afterAll'); } catch (e) { report(`${s.name || 'file'} (afterAll)`, e); }
  }
}

Object.assign(globalThis, {
  describe, test, it: test, expect,
  beforeAll: hook('beforeAll'), afterAll: hook('afterAll'),
  beforeEach: hook('beforeEach'), afterEach: hook('afterEach'),
});

let started = false;
process.on('beforeExit', async () => {
  if (started) return;
  started = true;
  await runSuite(root);
  console.log(`\n@@stator-ts ${JSON.stringify(counts)}`);
  process.exit(counts.failed > 0 ? 1 : 0);
});

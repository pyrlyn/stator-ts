declare let x: string | undefined;
declare function log(): void;

// Literals and constructs whose truthiness is known from the syntax.
if ({}) {}
if ([]) {}
if ("") {}
if ("a") {}
if (null) {}
if (undefined) {}
if (void 0) {}
if (/re/) {}
if (() => 1) {}
if (function named() {}) {}
if (class K {}) {}
const t = 2 ? 1 : 0;
const u = !{};
const v = {} && x;
const w = x || "fallback";
for (; "go";) break;
while ({} satisfies unknown) break;
while (((([])))) break;
do {} while (x ? {} : []);

// `while (1)` and `while (0)` are idioms.
while (1) break;
while (0) {}

// `void` results cannot be tested.
if (log()) {}
const r = log() && 1;

// `??` whose left side is never, or always, nullish.
const a = "s" ?? x;
const b = null ?? x;
const c = (x, 1) ?? 2;
const e = x ?? "y";
const f = undefined ?? x ?? "z";
const g = (x = "q") ?? 1;
const h = x?.length ?? 0;

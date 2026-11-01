const a1: (string | boolean | null)[] = ['a', false, null];
const a2: (string | boolean | null)[] | (string | boolean)[] = ['a', false, null];
declare const b1: (string | false | null)[];
const b2: (string | boolean | null)[] = b1;
const b3: (string | boolean | null)[] | (string | boolean)[] = b1;
interface PR { s: (m: string) => void }
const r1: PR = { s(m: string) {} };
const r2: PR = { s: function (m: string) {} };
const r3: PR = { s: (m: string) => {} };
const r4: PR = { s(m) {} };

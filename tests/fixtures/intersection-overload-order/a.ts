interface Late {
  start(handler: () => void): 'late';
}

declare global {
  function startTimer(handler: () => void): 'global';
}

interface Host {
  startTimer(handler: () => void): number;
}

// `Global` gets its id first, which must not move it ahead of `Host` in the intersection.
type Global = typeof globalThis;
declare const global: Global;
export const early: 'global' = global.startTimer(() => {});

type Both = Host & Global;
declare const both: Both;
export const first: number = both.startTimer(() => {});

type Reversed = Global & Host;
declare const reversed: Reversed;
export const second: 'global' = reversed.startTimer(() => {});

interface A { m(x: string): 'a' }
interface B { m(x: string): 'b' }
declare const b: B;
declare const a: A;
export const touched: ['b', 'a'] = [b.m(''), a.m('')];
declare const ab: A & B;
declare const ba: B & A;
export const fromAB: 'a' = ab.m('');
export const fromBA: 'b' = ba.m('');

// error: the first member wins, so this is not the second one's result.
export const wrong: 'b' = ab.m('');

declare const late: Late;
export const done = late.start(() => {});

// An empty source tells nothing about `T`, so the return context decides; a
// source with properties is reversed through the instantiated template.
function upcast<T>(partial: Partial<T>): T { return partial as T; }
interface Ref { repo: string; number: number }
interface Res { ref: Ref; n: string }
export const r: Res = { ref: upcast({}), n: 'x' };
export const q: Ref = upcast({ repo: 'a' });

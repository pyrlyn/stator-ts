interface IF extends Function { amd?: boolean }
interface W { define?: IF }
declare const w: W;
if (typeof w.define === 'function' && w.define.amd) {}
declare const m: IF | string;
if (typeof m === 'function') { m.amd; } else { m.length; }

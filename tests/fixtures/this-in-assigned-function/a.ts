interface El { name: string; run?: () => void }
declare const el: El;
el.run = function () { const n: number = this.name; };
el.run ??= function () { const n: number = this.name; };
el.run ||= function () { const n: number = this.name; };
const free = function () { return this; };

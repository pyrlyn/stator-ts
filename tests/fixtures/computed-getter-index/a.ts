const sym = Symbol();
const k = "lit";
declare const key: string;
const o = {
  get [sym]() { return 1; },
  get [k]() { return "a"; },
  get [key]() { return true; },
};
const a: string = o[sym];
const b: number = o.lit;
const c: string = o["other"];

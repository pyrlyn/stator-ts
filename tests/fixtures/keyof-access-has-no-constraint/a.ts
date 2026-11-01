type Plain<T> = { [K in keyof T]: T[K] };
function g<T extends { a: 1 } | { a: 2 }>(m: Plain<T>) { const x: { [k: string]: number } = m; }
function h<T extends { a: 1 }>(m: Plain<T>) { const x: { [k: string]: number } = m; }
function k<T extends { a: 1; b: 2 }>(m: Plain<T>) { const x: { [k: string]: T["a"] | T["b"] } = m; const y = Object.entries(m); const zz: "zz" = y; }
function l<T extends { a: 1; b: 2 }>(v: T[keyof T]) { const x: number = v; const y: T["a"] | T["b"] = v; }

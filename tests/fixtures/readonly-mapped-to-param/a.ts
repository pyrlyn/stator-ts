function ro<T>(a: Readonly<T>): T { return a; }
function ro2<T>(a: Readonly<T> | undefined): T | undefined { return a; }
function pa<T>(a: Partial<T>): T { return a; }
function re<T>(a: Required<T>): T { return a; }
function pi<T, K extends keyof T>(a: Pick<T, K>): T { return a; }

function all(v: unknown): string {
  switch (typeof v) {
    case 'string':
    case 'number':
    case 'bigint':
    case 'boolean':
    case 'symbol':
    case 'undefined':
    case 'object':
    case 'function':
      return 'x';
  }
}
function allAny(v: any): number {
  switch (typeof v) {
    case 'string':
    case 'number':
    case 'bigint':
      return 1;
    case 'boolean':
    case 'symbol':
    case 'undefined':
    case `object`:
    case 'function':
      return 2;
  }
}
function missing(v: unknown): string {
  switch (typeof v) {
    case 'string':
    case 'number':
    case 'bigint':
    case 'boolean':
    case 'symbol':
    case 'undefined':
    case 'object':
      return 'x';
  }
}
function union(v: string | number | null | (() => void)): string {
  switch (typeof v) {
    case 'string':
    case 'number':
    case 'object':
    case 'function':
      return 'x';
  }
}
function unionLeft(v: string | number): string {
  switch (typeof v) {
    case 'string':
      return 'x';
  }
}
function generic<T extends string | boolean>(v: T): string {
  switch (typeof v) {
    case 'string':
    case 'boolean':
      return 'x';
  }
}
function emptyObject(v: {}): string {
  switch (typeof v) {
    case 'string':
    case 'number':
    case 'bigint':
    case 'boolean':
    case 'symbol':
    case 'undefined':
    case 'object':
    case 'function':
      return 'x';
  }
}
const word = 'string';
function computed(v: string): string {
  switch (typeof v) {
    case word:
      return 'x';
  }
}

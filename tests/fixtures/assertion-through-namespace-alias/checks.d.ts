declare module 'checks' {
  function ok(value: unknown, message?: string): asserts value;
  function ok(value: unknown, message: string, ...args: unknown[]): asserts value;
  function single(value: unknown): asserts value;
  function equal<T>(actual: unknown, expected: T): asserts actual is T;
  function plain(value: unknown): void;
  const typed: (value: unknown) => asserts value;
  const inferred: typeof ok;
  namespace api {
    export { ok, single, equal, plain, typed };
  }
  export default api;
}

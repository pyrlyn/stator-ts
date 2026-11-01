declare function isOneOf<TType, TSubtype extends TType>(value: TType, validValues: readonly TSubtype[]): value is TSubtype;
function f<TObject extends object>(key: string | number | Symbol, keys: (keyof TObject)[]) {
  isOneOf(key, keys);
  const s: Symbol = Symbol();
  const ok: readonly (string | number | Symbol)[] = keys;
  const k: string | number | Symbol = keys[0];
}

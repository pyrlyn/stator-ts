interface Eff<R> { run(): R }
interface Layer<T> { layer: T }
interface Tag<T> { tag: T }
declare function layerEffect<T>(tag: Tag<T>, e: Eff<T>): Layer<T>;
declare function effectGen<R>(f: () => Generator<unknown, R>): Eff<R>;
declare const Foo: Tag<{ run(): number; list: string[] }>;
const ok = layerEffect(Foo, effectGen(function* () {
  yield 1;
  return { run() { return 1; }, list: [] };
}));
const bad = layerEffect(Foo, effectGen(function* () {
  return { run() { return 's'; }, list: [] };
}));

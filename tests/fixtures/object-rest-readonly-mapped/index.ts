declare const frozen: Readonly<{ foo: string; bar: number; readonly baz: boolean }>;
const { foo, ...rest } = frozen;
rest.bar = 1;
rest.baz = true;
frozen.bar = 2;
export { foo };

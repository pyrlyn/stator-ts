declare const dec: any;

export function f(@dec this: unknown) {}
@dec enum Hidden {}
export { Hidden };

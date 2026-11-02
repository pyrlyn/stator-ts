// Untyped parameters that no context can type are `any`, and still narrow.
const isList = (arg) => Array.isArray(arg);
const list: (x: any) => x is any[] = isList;

function isText(x) {
    return typeof x === "string";
}
const text: (x: any) => x is string = isText;

class Guards {
    isNumber(x) {
        return typeof x === "number";
    }
}
const num: (x: any) => x is number = new Guards().isNumber;

// A lambda in a typed slot waits for its context, so it is no predicate of `any`.
const typed: (x: string | number) => boolean = (x) => typeof x === "string";
const wrong: (x: string | number) => x is number = typed;

export {};

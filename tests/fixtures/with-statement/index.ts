// tsc checks only the object of a `with`, never its body.
declare const obj: { a: number };
with (obj) {
    let x: string = 1;
    undefinedName;
}
with (obj) /* ) */ var y: string = 2;

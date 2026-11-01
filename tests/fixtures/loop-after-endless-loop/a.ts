export function endless(input: string | number): void {
    for (;;) {}
    for (let i = 0; i < 2; i++) {
        let x = input;
        if (typeof x === "string") x = 1;
        x.toString();
    }
}

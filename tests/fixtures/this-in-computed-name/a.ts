export class C {
    bar(): number {
        const obj = {
            [this.bar()]() {},
        };
        obj;
        return 0;
    }
}

export class Accessors {
    get missing() {
        console.log("no return");
    }
    get bare() {
        return;
    }
    get throws(): number {
        throw new Error();
    }
    get value() {
        return 1;
    }
}

export const literal = {
    get noReturn() {
        if (Math.random()) return 1;
    },
    get empty() {},
};

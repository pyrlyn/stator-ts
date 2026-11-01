export class C {
    #a = 1;
    m(x: typeof this.#a) {
        return x;
    }
}

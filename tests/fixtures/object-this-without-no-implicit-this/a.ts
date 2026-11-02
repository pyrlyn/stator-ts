export {};

const object = {
    method() { return this.absent; },
    property: function () { return this.absent; },
    nested() { return () => this.absent; },
    get value() { return this.absent; },
    set value(value: number) { this.absent = value; },
};
const numeric: number = object.method();
const textual: string = object.method();

const explicit = {
    method(this: { value: number }) { return this.absent; },
};
const contextual: { method(this: { value: number }): void } = {
    method() { this.absent; },
};
class Example {
    method() { return this.absent; }
}

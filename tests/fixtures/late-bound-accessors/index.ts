const key = "value";
const other = "other";

// A setter takes its parameter type from the getter of the same name, late-bound or not.
export class C {
    get [key]() { return 0; }
    set [key](v) { }
    static get [key]() { return ""; }
    static set [key](v) { }
    get [other]() { return 0; }
    static set [other](v) { }
}

new C()[key] = 1;
new C()[key] = "no";
C[key] = "yes";

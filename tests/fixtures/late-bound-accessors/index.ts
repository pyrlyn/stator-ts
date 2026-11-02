const key = "value";

// A setter takes its parameter type from the getter of the same name, late-bound or not.
export class C {
    get [key]() { return 0; }
    set [key](v) { }
    static get [key]() { return ""; }
    static set [key](v) { }
}

new C()[key] = 1;
new C()[key] = "no";
C[key] = "yes";

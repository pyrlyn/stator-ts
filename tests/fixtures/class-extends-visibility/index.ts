class Base {
    private secret = 1;
    protected guarded = 1;
    open = 1;
}
class RedeclaresPrivate extends Base {
    private secret = 2;
}
class PrivatizesPublic extends Base {
    private open = 2;
}
class PrivatizesProtected extends Base {
    private guarded = 2;
}
class PublicizesProtected extends Base {
    guarded = 2;
}
class GrandChild extends PublicizesProtected {
    private secret = 3;
}

class Indexed {
    [x: string]: number;
}
class BadIndex extends Indexed {
    [x: string]: string;
}

class Fine extends Base {
    open = 5;
}

class RetypesPrivate extends Base {
    private secret = "s";
}

interface Shape {
    area(): number;
    name: string;
}
class WrongMember implements Shape {
    area() { return "big"; }
    name = "w";
}
class MissingMember implements Shape {
    area() { return 1; }
}

class Impl {
    run() {}
}
class ImplementsClass implements Impl {}
class Box<T> {
    value!: T;
}
class ImplementsGeneric implements Box<number> {}

interface Weak {
    hint?: string;
}
class NothingInCommon implements Weak {
    other = 1;
}

class StaticBase {
    static make(): number { return 1; }
    static label = "base";
    static get size() { return 1; }
}
class StaticRetyped extends StaticBase {
    static make(): string { return ""; }
}
class StaticNarrowed extends StaticBase {
    static label = "child";
}
class StaticPrivate extends StaticBase {
    private static label = "hidden";
}

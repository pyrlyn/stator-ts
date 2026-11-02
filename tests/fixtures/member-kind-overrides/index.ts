class WithAccessor {
    get p() { return "a"; }
    set p(v: string) {}
    accessor auto: number = 1;
    m() {}
}

class PropertyOverAccessor extends WithAccessor {
    p = "b";
    auto = 2;
}

class ParamOverAccessor extends WithAccessor {
    constructor(public p: string) {
        super();
    }
}

class WithProperty {
    x = 1;
    y = 2;
}

class Middle extends WithProperty {}

class AccessorOverProperty extends Middle {
    get x() { return 2; }
    accessor y = 3;
}

class FunctionOverMembers extends WithProperty {
    x() { return 1; }
}

class AccessorFunction extends WithAccessor {
    p() { return "c"; }
    get m() { return () => {}; }
}

class PropertyOverMethod extends WithAccessor {
    m = () => {};
}

interface Shape {
    size: number;
}
abstract class AbstractShape {
    abstract get size(): number;
    abstract area: number;
}
class Square extends AbstractShape implements Shape {
    size = 1;
    get area() { return 1; }
}

class WithPrivate {
    private z = 1;
}
class OverPrivate extends WithPrivate {
    // A private member is no override, though the class still fails to extend.
    get z() { return 1; }
}

export {};

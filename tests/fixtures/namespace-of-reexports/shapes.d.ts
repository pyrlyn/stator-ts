declare module 'shapes-source' {
  export function fromImport(): number;
}
declare module 'shapes' {
  import { fromImport } from 'shapes-source';

  function local(): number;
  interface Shape {
    a: number;
  }
  type Alias = string;
  class Thing {}
  namespace TypesInside {
    interface A {}
  }
  namespace ValueInside {
    const a: 1;
  }
  const v: 1;

  namespace OfImport {
    export { fromImport };
  }
  namespace OfFunction {
    export { local };
  }
  namespace OfClass {
    export { Thing };
  }
  namespace OfConst {
    export { v };
  }
  namespace OfValueNamespace {
    export { ValueInside };
  }
  namespace OfRenamed {
    export { local as renamed };
  }
  namespace OfInterface {
    export { Shape };
  }
  namespace OfAlias {
    export { Alias };
  }
  namespace OfTypeNamespace {
    export { TypesInside };
  }
  namespace Empty {
    export {};
  }
  namespace CircleA {
    export { CircleB };
  }
  namespace CircleB {
    export { CircleA };
  }

  export {
    OfImport,
    OfFunction,
    OfClass,
    OfConst,
    OfValueNamespace,
    OfRenamed,
    OfInterface,
    OfAlias,
    OfTypeNamespace,
    Empty,
    CircleA,
  };
}

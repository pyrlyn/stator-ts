export function overloaded(x: string);
export function overloaded(x: number): number;
export function overloaded(x: any) {
    return x;
}

export declare function ambient(a: number);

export interface Methods {
    plain();
    typed(): void;
}

export declare class Ambient {
    method();
    private hidden();
    #secret();
}

export abstract class Abstract {
    abstract run();
}

interface A {
    [key: string]: number;
    name: string;
    1: number;
    opt?: number;
}
interface B {
    [key: number]: string;
    0: number;
    other: boolean;
}
interface Base1 { x: string }
interface Base2 { [key: string]: number }
interface Both extends Base1, Base2 {}
interface Ok extends Base2 { y: number }
class C {
    [key: string]: number | (() => void);
    s = "no";
    n = 1;
    m() {}
    static [key: string]: boolean;
    static flag = true;
    static count = 1;
}
type L = {
    [key: string]: number;
    bad: string;
};
interface Two {
    [key: string]: string;
    [key: number]: number;
}
interface Tmpl {
    [key: `data-${string}`]: number;
    "data-x": string;
    plain: string;
}
interface Merged { [key: string]: number }
interface Merged { late: string }

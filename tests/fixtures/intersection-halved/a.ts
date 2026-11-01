// Distributed in one go this is 2^18 combinations; halved, the literals cancel out on the way.
type Each<T extends string[]> =
    & ("a" | T[0])
    & ("b" | T[1])
    & ("c" | T[2])
    & ("d" | T[3])
    & ("e" | T[4])
    & ("f" | T[5])
    & ("g" | T[6])
    & ("h" | T[7])
    & ("i" | T[8])
    & ("j" | T[9])
    & ("k" | T[10])
    & ("l" | T[11])
    & ("m" | T[12])
    & ("n" | T[13])
    & ("o" | T[14])
    & ("p" | T[15])
    & ("q" | T[16])
    & ("r" | T[17]);

declare function use<T extends string[]>(x: Each<T>): void;
export { use };

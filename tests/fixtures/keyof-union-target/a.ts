function f<T>(o: T, k: keyof T) {
    const p: PropertyKey = k;
    const q: string | number = k;
    return p;
}
export {};

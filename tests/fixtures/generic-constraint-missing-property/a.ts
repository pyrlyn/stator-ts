export function array<T, U extends readonly T[]>(items: U) {
    items.length;
    items.missing;
}

export function object<T, U extends { value: T }>(box: U) {
    box.value;
    box.missing;
}

export function indexed<T, U extends { [key: string]: T }>(dictionary: U) {
    return dictionary.missing;
}

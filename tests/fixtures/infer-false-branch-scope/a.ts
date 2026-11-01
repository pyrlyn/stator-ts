type Dto<T> = T extends { toJSON(): infer U } ? U : T extends object ? { [K in keyof T]: Dto<T[K]> } : T;

interface Location { uri: string; line: number }
type LocationDto = Dto<Location>;

// A mapped type in the false branch is a plain object: an array guard must tell it from an array.
export function revive(data: LocationDto | LocationDto[]): number {
  if (Array.isArray(data)) {
    return data[0].line;
  }
  return data.line;
}

// error: the same type is still not an array.
export const list: any[] = null! as LocationDto;

const s = Symbol("s");
interface Data {
  readonly from?: string;
  [key: string]: unknown;
}

export function read(data?: Data) {
  if (data && s in data) {
    return Boolean(data[s]);
  }
  return false;
}

// The string key is still covered by the index signature, so nothing is added here.
export function strings(data: Data) {
  if ("other" in data) {
    return data.other;
  }
  return data.other;
}

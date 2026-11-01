type Val<T> = T;
type EK<T> = Partial<{ [K in keyof T]: T[K] extends Function ? never : T[K] extends object ? EK<T[K]> : Val<number | T[K] | undefined | null> }>;
export function t4(attributes: EK<HTMLElement>) {
  for (const [key, value] of Object.entries(attributes)) {
    let n: never = value;
  }
  let q: never = attributes.dataset;
  let q1: never = attributes.style;
  let q2: never = attributes.hidden;
}

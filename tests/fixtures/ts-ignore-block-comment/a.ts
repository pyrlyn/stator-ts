/*
  @ts-ignore
*/
const a: number = "s";

/**
 * @ts-ignore
 */
const b: number = "s";

/*
 @ts-expect-error
 */
const c: number = "s";

/*** @ts-ignore */
const d: number = "s";

/*
   * @ts-ignore */
const e: number = "s";

export { a, b, c, d, e };

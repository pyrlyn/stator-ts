interface Request {
  method: string;
  params?: { [key: string]: any };
}

interface Params {
  cursor?: string;
}

// An interface has no implicit index signature, but `any` values ask for nothing.
interface Paged extends Request {
  params?: Params;
}

declare const params: Params;
export const open: { [key: string]: any } = params;
export const request: Request = null! as Paged;

class Point {
  x = 1;
}
export const instance: { [key: string]: any } = new Point();

// A numeric index alone gets no such pass.
export const numeric: { [key: number]: any } = params;

// error: a primitive is not an object.
export const text: { [key: string]: any } = 'text';

// error: only `any` skips the check.
export const typed: { [key: string]: string } = params;

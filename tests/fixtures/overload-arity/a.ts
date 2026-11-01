// Type arguments rule out overloads that take none, and a failed overload must not fix a method's parameters.
export const typed = new ReadableStream<Uint8Array>({ start(c) { c.close(); } });
export const inferred = new ReadableStream({ start(c) { c.close(); } });

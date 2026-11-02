declare const p: Promise<number>;
await p;
for await (const x of [p]) {}
export {};

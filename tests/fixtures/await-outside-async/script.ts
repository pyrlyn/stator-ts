declare const q: Promise<number>;
await q;
for await (const y of [q]) {}

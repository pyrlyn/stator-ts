// `"*"` brings back every visible `@types` package.
import { readFileSync } from "node:fs";
export const text: string = readFileSync("a.ts", "utf8");
export const cwd: string = process.cwd();
export const wrong: number = process.cwd();

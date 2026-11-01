// `@types/node` sits in `node_modules`, but since TS 6 it counts only when `types` names it.
import { readFileSync } from "node:fs";
import { join } from "path";
import { test } from "node:test";
import { mock } from "test";
export const text = readFileSync(join("a", "b"), "utf8");
export const cwd = process.cwd();
export const hooks = [test, mock, beforeEach, $];

import { value } from "selfpkg";
export const y: "import" = value;
export const wrong: "require" = value;
export const later = import("selfpkg").then(m => { const s: "require" = m.value; return s; });

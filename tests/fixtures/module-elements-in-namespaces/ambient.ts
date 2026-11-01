declare module "m1" { import x from "q1"; export { x }; export default x; import q = require("q2"); export * from "q3"; }

const key = "k";
const o = {
  get [missingName]() { return 1; },
  set [otherVar](v: number) {},
  get [key]() { return missingInBody; },
};
export { o };

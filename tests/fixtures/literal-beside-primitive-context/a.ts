interface Action { id: string; label: string; run(): void }
interface Separator { id: "separator" }
type Item = Action | Separator;
const items: Item[] = [];
items.push({ id: "separator" });
const one: Item = { id: "separator" };
export { one };

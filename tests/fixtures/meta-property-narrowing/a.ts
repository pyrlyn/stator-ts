export {};
declare global {
  interface ImportMeta { foo?: () => void }
}
if (import.meta.foo) import.meta.foo();
import.meta.foo();
function f() {
  if (new.target.marked === true) {
    const t: true = new.target.marked;
  }
}
f.marked = true;

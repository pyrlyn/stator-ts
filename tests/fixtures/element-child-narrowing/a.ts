type Child = HTMLElement | string | Record<string, HTMLElement>;
function isEl(x: unknown): x is HTMLElement { return false; }
export function f1(c: Child, el: HTMLElement) {
  if (isEl(c)) { el.appendChild(c); }
  else if (typeof c === 'string') { el.append(c); }
  else if ('root' in c) { c.x; }
}
type Attrs<T> = { [K in keyof T & string]?: string } & Record<string, any>;
export function f2(attributes: { $: string } & Partial<HTMLElement> & Record<string, any>, b: Record<string, any>) {
  for (const [key, value] of Object.entries(attributes)) {
    const z: number = value;
    for (const [k2, v2] of Object.entries(value)) { }
  }
  for (const [key, value] of Object.entries(b)) { const z: number = value; }
}
interface IG { Mon?: string }
export function f3() { return (globalThis as IG).Mon; }
export function f4(p: { firstChild: ChildNode | null }, children: Node[], ch2: any[]) {
  let cursor = p.firstChild;
  for (const child of children) {
    if (cursor === child) { cursor = cursor.nextSibling; }
  }
}
export function f5<K extends string, V>(r: Partial<Record<K, V[]>>, key: K, e: V) {
  let target = r[key];
  if (!target) { target = r[key] = []; }
  target.push(e);
}
interface PC { platform?: { kind: 'windows'; bypass: string } | { kind: 'macos'; ex: string[] } }
export function f6(config: PC) {
  switch (config.platform?.kind) {
    case 'windows': return !!config.platform.bypass;
    case 'macos': return config.platform.ex.length > 0;
  }
  return false;
}
type HK<T> = { [K in keyof T & string]?: string };
type EA<T> = HK<T> & Record<string, any>;
export function f7(args0: unknown) {
  let attributes: { $?: string } & Partial<EA<HTMLElement>> = {};
  for (const [key, value] of Object.entries(attributes)) {
    const z: number = value;
  }
}

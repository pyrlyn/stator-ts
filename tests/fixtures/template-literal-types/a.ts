// A template of constants is a literal, and a template used as a key keeps its literal shape.
const scheme = 'ahp';
enum Kind { Text = 'text', One = 1 }

export const uri = `${scheme}://`;
export const viaEnum = `${Kind.Text}-${Kind.One}-${2}`;
export const joined = `${scheme + '-x'}`;

declare function takeUri(x: { channel: 'ahp://' }): void;
takeUri({ channel: uri });

declare function takeKind(x: 'text-1-2'): void;
takeKind(viaEnum);

declare function takeJoined(x: 'ahp-x'): void;
takeJoined(joined);

declare const stats: { aCount: number; bCount: number };
declare const which: 'a' | 'b';
stats[`${which}Count`]++;

// `let` widens the literal again, and a runtime value keeps the template a plain string.
let open = `${scheme}:`;
open = 'other';
export const opened = open;

declare const name: string;
export const plain: string = `${name}!`;

// A template key is a string, so a string index signature takes it.
declare const table: Record<string, number>;
table[`${name}.x`] = 1;
export const read: number = table[`${name}.y`];

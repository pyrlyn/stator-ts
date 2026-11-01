import { M1, M2 } from './b';
const M3 = 'vscode/m3';
export interface Map1 { [M1]: { r: 1 }; [M2]: { r: 2 }; [M3]: { r: 3 }; plain: { r: 4 }; }
declare function send<K extends keyof Map1>(k: K): Map1[K]['r'];
const a = send(M1);
const b = send(M2);
const c = send(M3);
const d = send('plain');
const e: 1 = a;
const f: Map1['vscode/m1'] = { r: 1 };

declare const ys: { limitHit: boolean }[];

export function any(): boolean {
	return ys.reduce((prev, cur) => prev || cur.limitHit, false);
}

export const summary: { limitHit: boolean } = {
	limitHit: ys.reduce((prev, cur) => prev || cur.limitHit, false),
};

declare function wrap<T>(x: T): { value: T };
export const literal: { value: "a" | boolean } = wrap("a");

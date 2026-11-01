interface Bind<I> { item: I; render(): void }
interface Tpl<I, B extends Bind<I>> { bind(item: I): B; current: B | undefined }
class M<I, B extends Bind<I>, TT extends Tpl<I, B>> {
	constructor(readonly t: TT, readonly item: I) {}
	f() {
		const template = this.t;
		let nb: B | undefined;
		nb = template.bind(this.item);
		nb.render();
		const v: B = nb;
		const wrong: "zz" = template;
		const wrong2: "zz" = nb;
		const wrong3: Bind<string> = nb;
		const wrong4: undefined = nb;
		const ok: Bind<I> = nb;
		const ok2: { render(): void } = template.bind(this.item);
	}
}

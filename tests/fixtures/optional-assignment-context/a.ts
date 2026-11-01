declare function make<T extends HTMLElement>(d: string): T;
declare function box<T>(): T;

class H {
	title?: HTMLDivElement;
	other?: { a: number };
	head(): void {
		this.title = make('.a');
		this.other = box();
		this.other = { a: 1 };
	}
	// A real error: the context does not admit a string.
	bad(): void {
		this.title = 'x';
	}
}

export const h = new H();

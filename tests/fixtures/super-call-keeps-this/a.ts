abstract class Marker {
	child?: Marker;
	appendChild(child: Marker): this { this.child = child; return this; }
}
class Snip extends Marker {
	override appendChild(child: Marker) {
		return super.appendChild(child);
	}
	x = 1;
}
class Plain extends Marker {
	appendChild(child: Marker) {
		const r = super.appendChild(child);
		return r;
	}
}
class Other extends Snip {
	own = "";
	override appendChild(child: Marker) {
		return super.appendChild(child);
	}
}
const s = new Snip().appendChild(new Snip());
const n: number = s.x;
const o = new Other().appendChild(new Snip());
const q: string = o.own;

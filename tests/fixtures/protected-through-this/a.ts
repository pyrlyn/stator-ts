class Base {
	protected value = 1;
	protected static shared = 2;
	protected read() { return this.value; }
}
class Derived extends Base {}
class Other { protected value = 1; }

function viaParam(this: Base) {
	return this.value + this.read();
}
function viaDerived(this: Derived) {
	return this.value;
}
function viaConstraint<T extends Base>(this: T) {
	return this.value;
}
const inObject = {
	method(this: Base) {
		return this.value;
	},
};
const contextual: { run(this: Base): number } = {
	run() {
		return this.value;
	},
};
const arrow = function (this: Base) {
	return () => this.value;
};

function notDerived(this: Other, base: Base) {
	return base.value;
}
function noThis(base: Base) {
	return base.value;
}
function staticNotReached(this: typeof Base) {
	return this.shared;
}

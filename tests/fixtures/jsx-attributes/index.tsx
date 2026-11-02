declare namespace JSX {
  interface Element {}
  interface ElementAttributesProperty { props: {}; }
  interface ElementChildrenAttribute { children: {}; }
  interface IntrinsicElements {
    div: { id?: string; hidden?: boolean };
  }
}

// Intrinsic elements: a wrong value, an unknown name, a hyphenated name.
const a = <div id={1} />;
const b = <div title="x" />;
const c = <div data-x="1" hidden />;
const d = <span />;

// Function components: missing and excess props.
declare function Button(props: { label: string; size?: number }): JSX.Element;
const e = <Button />;
const f = <Button label="ok" size="big" />;
const g = <Button label="ok" color="red" />;

// Spread props are not excess; written ones are.
const rest = { label: "x", extra: 1 };
const h = <Button {...rest} />;

// A union of props is narrowed by the discriminant for contextual typing.
type Choice = { on: true; cb: (x: string) => void } | { on?: false; cb: (x: number) => void };
declare function Toggle(props: Choice): JSX.Element;
const i = <Toggle on cb={s => s.length} />;
const j = <Toggle cb={n => n.toFixed()} />;

// Children take the children property's type as their context.
declare function List(props: { children: (n: number) => string }): JSX.Element;
const k = <List>{n => n.toFixed()}</List>;
const l = <List>{n => n}</List>;

// Class components read props from the ElementAttributesProperty member.
declare class Panel { props: { title: string }; }
const m = <Panel title={3} />;

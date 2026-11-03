declare namespace JSX {
    interface Element {}
}

declare const Widget: any;

export const plain = <div>text</div>;
export const self = <span />;
export const dashed = <my-element />;
export const component = <Widget />;
export const nested = <section><p>{1}</p></section>;

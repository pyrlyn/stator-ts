declare namespace React {
    namespace JSX {
        interface Element {}
        interface IntrinsicElements { div: {} }
    }
}

export const fromFactory = <div />;

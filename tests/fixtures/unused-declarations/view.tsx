import * as React from "./values";

declare global {
    namespace JSX {
        interface IntrinsicElements { div: {} }
    }
}

export const view = <div />;

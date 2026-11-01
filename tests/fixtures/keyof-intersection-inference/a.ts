declare class Component<P> {
  constructor(props: Readonly<P>);
  readonly props: Readonly<P>;
}
class C<T> extends Component<{ x?: boolean } & T> {}
const y = new C({ foobar: 'example' });
const a: string = y.props.foobar;
const b: number = y.props.foobar;
type LowInfer<T> = T & {};
type Assign<T> = { [K in keyof T]?: T[K] };
declare function assign<T>(a: Assign<LowInfer<T>>): (x: T) => void;
const low: (x: { c: number }) => void = assign({ c: 1 });

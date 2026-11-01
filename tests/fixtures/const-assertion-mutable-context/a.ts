interface Schema {
  type?: string;
  required?: string[];
  items?: Schema[];
  fixed?: readonly string[];
  pair?: [string, string];
}

// A mutable array in the context keeps the tuple mutable, a readonly one does not.
const schema = {
  type: 'object',
  required: ['vendor', 'name'],
  items: [{ type: 'string' }],
  fixed: ['a'],
  pair: ['a', 'b'],
} as const satisfies Schema;

type IsMutable<T> = T extends [infer First, ...infer _] ? First : 'readonly';

export const first: 'vendor' = null! as IsMutable<typeof schema.required>;
export const pair: 'a' = null! as IsMutable<typeof schema.pair>;
export const fixed: 'readonly' = null! as IsMutable<typeof schema.fixed>;

const plain = ['x'] as const;
export const direct: 'readonly' = null! as IsMutable<typeof plain>;

// error: the literal keeps its readonly tuple without a context.
export const wrong: 'x' = null! as IsMutable<typeof plain>;

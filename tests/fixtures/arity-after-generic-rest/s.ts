export type TypeFromJsonSchema<T> =
	// enum
	T extends { enum: infer EnumValues }
	? UnionOf<EnumValues>

	// Object with list of required properties.
	// Values are required or optional based on `required` list.
	: T extends { type: 'object'; properties: infer P; required: infer RequiredList }
	? {
		[K in keyof P]: IsRequired<K, RequiredList> extends true ? TypeFromJsonSchema<P[K]> : TypeFromJsonSchema<P[K]> | undefined;
	} & AdditionalPropertiesType<T>

	// Object with no required properties.
	// All values are optional
	: T extends { type: 'object'; properties: infer P }
	? { [K in keyof P]: TypeFromJsonSchema<P[K]> | undefined } & AdditionalPropertiesType<T>

	// Array
	: T extends { type: 'array'; items: infer Items }
	? Items extends [...infer R]
	// If items is an array, we treat it like a tuple
	? { [K in keyof R]: TypeFromJsonSchema<Items[K]> }
	: Array<TypeFromJsonSchema<Items>>

	// oneOf / anyof
	// These are handled the same way as they both represent a union type.
	// However at the validation level, they have different semantics.
	: T extends { oneOf: infer I }
	? MapSchemaToType<I>
	: T extends { anyOf: infer I }
	? MapSchemaToType<I>

	// Primitive types
	: T extends { type: infer Type }
	// Basic type
	? Type extends 'string' | 'number' | 'integer' | 'boolean' | 'null'
	? SchemaPrimitiveTypeNameToType<Type>
	// Union of primitive types
	: Type extends [...infer R]
	? UnionOf<{ [K in keyof R]: SchemaPrimitiveTypeNameToType<R[K]> }>
	: never

	// Fallthrough
	: never;

type SchemaPrimitiveTypeNameToType<T> =
	T extends 'string' ? string :
	T extends 'number' | 'integer' ? number :
	T extends 'boolean' ? boolean :
	T extends 'null' ? null :
	never;

type UnionOf<T> =
	T extends [infer First, ...infer Rest]
	? First | UnionOf<Rest>
	: never;

type IsRequired<K, RequiredList> =
	RequiredList extends []
	? false

	: RequiredList extends [K, ...infer _]
	? true

	: RequiredList extends [infer _, ...infer R]
	? IsRequired<K, R>

	: false;

type AdditionalPropertiesType<Schema> =
	Schema extends { additionalProperties: infer AP }
	? AP extends false ? {} : { [key: string]: TypeFromJsonSchema<Schema['additionalProperties']> }
	: {};

type MapSchemaToType<T> = T extends [infer First, ...infer Rest]
	? TypeFromJsonSchema<First> | MapSchemaToType<Rest>
	: never;


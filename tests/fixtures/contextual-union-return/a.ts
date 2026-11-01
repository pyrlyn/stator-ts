// A lambda under a union of functions may return what any member wants. Members sort by type id,
// so `Prompt` coming first must not make `run` lose its context.
type Prepared<T> = { kind: "ready"; value: T } | { kind: "skip"; reason: string };

interface Prompt {
	text: string;
}

interface Execution {
	run(): Promise<{ kind: "completed"; summary: string }>;
}

declare const prompted: Prepared<Prompt>;
declare const executed: Prepared<Execution>;

type PromptAction = { kind: "prompt"; prepare(): Promise<Prepared<Prompt>> };
type CodeAction = { kind: "code"; prepare(): Promise<Prepared<Execution>> };
type Action = PromptAction | CodeAction;

declare const code: CodeAction;
declare const prompt: PromptAction;

const asking: Action = {
	...prompt,
	prepare: async () => ({ kind: "ready", value: { text: "go" } }),
};

const running: Action = {
	...code,
	prepare: async () => ({ kind: "ready", value: { run: async () => ({ kind: "completed", summary: "Done" }) } }),
};

const wrong: Action = {
	...code,
	prepare: async () => ({ kind: "ready", value: { run: async () => ({ kind: "failed", summary: "Done" }) } }),
};

export { running, asking, wrong, prompted, executed };

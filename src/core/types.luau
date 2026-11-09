--!strict
-- The workbench's data model. A Matter is one thing that asks for you: a message,
-- or a run of mentions from one sender folded into it. Its state has three
-- independent parts: what AI made of it (`analysis`), what you did with it
-- (`disposition`), and the task tab working on it (`task`).

local history = require("./history")

export type Pri = "P0" | "P1" | "P2" | "P3"
export type Kind = "fyi" | "reply" | "deep"

-- What AI (or you, `manual`) decided about a matter.
export type Judgment = {
	kind: Kind,
	pri: Pri,
	summary: string,
	why: string,
	draft: string,
	risk: string,
	task: { title: string, prompt: string, workspace: string },
	manual: boolean,
}

export type Phase = "queued" | "running" | "failed" | "done"

export type Analysis = {
	phase: Phase,
	-- Bumped on every start; a result carrying an older one is dropped.
	gen: number,
	stage: string?,
	resumed: boolean?,
	judgment: Judgment?,
	error: string?,
	session: string?,
	-- The last message the session has seen, so a follow-up sends only what is new.
	through: string?,
	-- Not before this time: a chat still moving gets a moment to finish.
	settle_at: number?,
	-- Found by loading older pages: analyzed only once selected.
	backlog: boolean,
	-- Analyze even though a rule keeps this chat from AI.
	force: boolean,
	-- New messages arrived during a running turn.
	reanalyze: boolean,
	-- You asked to stop this running turn; its result is reported as stopped. Not persisted.
	stopping: boolean?,
	run: any,
}

-- nil: open. Persisted per message id, so these strings are a storage format.
export type Disposition = "handoff" | "snoozed" | "doing" | "archived" | "replied"

export type TaskPhase = "starting" | "working" | "waiting" | "done" | "closed"

export type Task = {
	phase: TaskPhase,
	-- What the tab last said, with any <reply> block removed.
	result: string?,
	-- The raw text, to tell a new result from the same one.
	raw: string?,
	-- Messages that arrived after the task started.
	new_messages: number,
	request_id: number?,
	revision: number?,
	workspace: string?,
	default_workspace: string?,
	task_text: string?,
	title: string?,
	-- Started on its own after a bot command; the window opens it without a workbench.
	auto: boolean?,
}

export type ThreadMessage = {
	id: string,
	sender: string,
	time: string,
	content: string,
	deleted: boolean,
	mine: boolean,
}

export type Talk = { me: boolean?, text: string }

export type TaskContext = {
	gen: number, revision: number, task: string,
	phase: "thread" | "model" | "ready" | "failed",
	prompt: string?, needs: any, error: string?,
}

export type Matter = {
	id: string,
	-- Changes when a confirmed task's inputs change.
	revision: number,
	chat_id: string,
	chat: string,
	chat_type: string,
	name: string,
	sender_id: string,
	sender_type: "user" | "bot" | "unknown",
	time: string,
	content: string,
	deleted: boolean,
	link: string?,
	mention: boolean,
	via: string,
	-- Ids of the earlier messages folded into this one.
	folded: { string },
	-- The newest folded message, when it is not `id`.
	latest_id: string?,
	is_read: boolean?,

	analysis: Analysis,
	disposition: Disposition?,
	handoff_at: number?,
	-- Your own message seen after a handoff.
	spoken: string?,
	-- Why a settled matter came back.
	reopened: string?,
	task: Task?,
	edits: { reply: string?, task: string?, workspace: string? },
	task_workspace_unconfirmed: boolean?,
	talk: { Talk },
	thread: { ThreadMessage }?,
	thread_error: string?,

	-- Derived on every rule pass, never stored.
	hidden: boolean,
	no_agent: boolean,
	-- A relevance check is running for a task start (its generation).
	preparing: number?,
	-- A thread fetch is in flight.
	loading_thread: boolean?,
	thread_gen: number?,
	preparation: any,
	-- Context assessment belongs to the deep-task card, before confirmation. Transient.
	context: TaskContext?,
	-- What you asked for when you @-ed the bot about this message; analysis takes it
	-- as your own words. With `auto_task`, a deep judgment starts its task by itself.
	-- `urgent` jumps the queue past settling, backlog, concurrency and pauses. Not saved.
	instruction: string?,
	auto_task: boolean?,
	urgent: boolean?,
}

export type Undo = { kind: "triage", id: string, previous: Disposition? }
	| { kind: "rule", id: string, chat_id: string, previous: any }

export type Cursor = { token: string?, since: number?, paged: boolean?, exhausted: boolean? }

export type Image = { path: string?, failed: boolean?, pending: boolean?, blob: any }

-- Settings, rules and stars as of this dispatch: the core never reads storage.
export type Config = {
	settings: { [string]: any },
	rules: { [string]: { mode: string, name: string } },
	stars: { { id: string, name: string } },
	now: number,
	home: string?,
	-- A workbench pane is open; without one, work runs only if background is allowed.
	visible: boolean?,
	-- Your open_id as the dedicated bot app sees you, once bound; nil disables commands.
	bot_owner: string?,
	bot_id: string?,
}

export type Model = {
	items: { Matter },
	cfg: Config,
	me: string?,
	view: string,
	source: string,
	person: string?,
	selected: string?,
	-- A phone-width pane shows the selected message instead of the queue. Not saved.
	reading: boolean?,
	history: history.State?,
	page: string?,
	mode: string?,
	command: string,
	command_cursor: number,
	draft_cursor: number,
	settings_cursor: string,
	field_cursor: number,
	log: { { t: string, who: string, text: string } },
	flash: string?,
	undo: Undo?,
	problem: string?,
	-- Transient, never saved: the omp workspace fallback is reported again on the next turn.
	runtime_warning: string?,
	-- The last workbench event write failure; the next successful write clears it. Not saved.
	event_warning: string?,
	loading: boolean,
	loading_more: boolean,
	last_refresh: number?,
	backlog_marked: boolean,
	agenda: any,
	chat_settings: { [string]: any }?,
	cursors: { [string]: Cursor },
	dialog: string?,
	talking: string?,
	images: { [string]: Image },
	gen: number,
	-- Once a load has succeeded the queue is worth keeping; before that nothing is saved.
	loaded: boolean,
	wake_at: number?,
	fetch_gen: number?,
	queue_enabled: boolean?,
	chat_request: any,
	-- The binding code and listener error are transient. Accepted command IDs are
	-- checkpointed to prevent event redelivery from starting a second task.
	bot_code: string?,
	bot_problem: string?,
	bot_seen: { [string]: boolean }?,
}

return {}

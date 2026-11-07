--!strict
local t = require("./t")
local snapshot = require("../src/core/snapshot")
local types = require("../src/core/types")
local status = require("../src/core/status")

local function config(): types.Config
	return { settings = { agent_enabled = true, show_images = true }, rules = {}, stars = {}, now = 1234567890 }
end

-- Only synthetic data: never copy a user's queue into migration fixtures.
local function legacy_item(id: string): any
	return {
		id = id, chat_id = "chat-example", chat = "Example group", chat_type = "group",
		name = "Example sender", sender_id = "sender-example", sender_type = "user",
		time = "2026-01-02 03:04", content = "Synthetic message", deleted = false,
		link = "https://example.invalid/message", mention = true, via = "@我", folded = {},
		agent = "done", analysis = {
			state = "reply", pri = "P1", summary = "Synthetic summary", why = "Synthetic reason",
			draft = "Synthetic draft", risk = "", task = { title = "Synthetic title", prompt = "Synthetic task" },
		},
	}
end

local function restored(stored: any, cfg: types.Config?): types.Model
	local model = snapshot.decode(stored, cfg or config())
	assert(model)
	return model
end

local function model_with_item(): types.Model
	return restored({ version = 1, items = { legacy_item("message-example") } })
end

local function packed(): any
	return snapshot.encode(model_with_item())
end

t.test("only an absent snapshot is no data", function()
	t.eq(snapshot.decode(nil, config()), nil)
	for _, value in { false, 0, "", {} } do
		t.errors(function() snapshot.decode(value, config()) end, "snapshot")
	end
	for _, version in { 0, 4, "2" } do
		t.errors(function() snapshot.decode({ version = version, items = {} }, config()) end, "Unsupported inbox snapshot version")
	end
end)

t.test("empty models use the supplied config and fresh runtime defaults", function()
	local cfg = config()
	local first, second = snapshot.empty(cfg), snapshot.empty(cfg)
	t.eq(first.cfg, cfg)
	t.eq(first.view, "pending")
	t.eq(first.source, "all")
	t.eq(first.command, "")
	t.eq(first.settings_cursor, "agent_enabled")
	t.eq(first.loaded, false)
	t.eq(first.loading, false)
	t.eq(first.loading_more, false)
	t.eq(first.gen, 0)
	t.eq(first.wake_at, nil)
	t.eq(first.talking, nil)
	t.eq(first.items == second.items, false)
	t.eq(first.images == second.images, false)
	t.eq(first.cursors == second.cursors, false)
	t.eq(first.log == second.log, false)
end)

t.test("v1 migrates source, folded ids, judgment, edits, thread and session", function()
	local old = legacy_item("message-example")
	old.folded = { "earlier-example", "latest-example" }
	old.latest_id, old.is_read = "latest-example", false
	old.edited, old.task_edited = "User reply", "User task"
	old.session, old.analyzed_through = "session-example", "through-example"
	old.backlog, old.force, old.settle_at = true, true, 999
	old.thread_error, old.reopened = "Synthetic fetch error", "Synthetic follow-up"
	old.thread = { { id = "thread-example", sender = "Example", time = "2026-01-02 03:00", content = "Thread context", deleted = false } }
	old.talk = { { me = true, text = "User question" }, { text = "Agent answer" } }
	old.run = { steps = { { tool = "read", target = "synthetic.txt" } }, more_steps = 0, seconds = 2, cost = 0.1 }
	local cfg = config()
	local model = restored({ version = 1, items = { old }, view = "mention", image_paths = { image_example = "images/example.png" } }, cfg)
	local item = model.items[1]
	t.eq(model.cfg, cfg)
	t.eq(cfg.settings.agent_enabled, true)
	t.eq(model.loaded, true)
	t.eq(model.view, "pending")
	t.eq(model.source, "mention")
	t.eq(model.images.image_example.path, "images/example.png")
	t.eq(item.revision, 0)
	t.eq(item.mention, true)
	t.eq(item.via, "@我")
	t.eq(item.is_read, false)
	t.eq(#item.folded, 2)
	t.eq(item.latest_id, "latest-example")
	t.eq(item.analysis.phase, "done")
	assert(item.analysis.judgment)
	t.eq(item.analysis.judgment.kind, "reply")
	t.eq(item.analysis.judgment.manual, false)
	t.eq(item.edits.reply, "User reply")
	t.eq(item.edits.task, "User task")
	t.eq(item.analysis.session, "session-example")
	t.eq(item.analysis.through, "through-example")
	t.eq(item.analysis.backlog, true)
	t.eq(item.analysis.force, true)
	t.eq(item.analysis.settle_at, 999)
	t.eq(item.analysis.run.steps[1].tool, "read")
	assert(item.thread)
	t.eq(item.thread[1].mine, false)
	t.eq(item.thread_error, "Synthetic fetch error")
	t.eq(item.reopened, "Synthetic follow-up")
	t.eq(item.talk[1].me, true)
	t.eq(item.talk[2].text, "Agent answer")
	t.eq((item :: any).agent, nil)
	t.eq((item :: any).edited, nil)
	t.eq((item :: any).thread_for_agent, nil)
end)

t.test("v1 sent and its undo become replied without changing the fixture", function()
	local old = legacy_item("message-example")
	old.triage = "sent"
	local stored = { version = 1, items = { old }, undo = { kind = "triage", id = old.id, previous = "sent" } }
	local model = restored(stored)
	t.eq(model.items[1].disposition, "replied")
	t.eq(status.settled(model.items[1]), true)
	assert(model.undo and model.undo.kind == "triage")
	t.eq(model.undo.previous, "replied")
	t.eq(old.triage, "sent")
	t.eq(stored.undo.previous, "sent")
end)

t.test("v1 minimal entries and manual judgments get real defaults", function()
	local model = restored({ version = 1, items = { { id = "minimal-example", folded = {} } }, view = "dm" })
	t.eq(model.source, "dm")
	t.eq(model.items[1].analysis.phase, "queued")
	t.eq(#model.items[1].talk, 0)
	t.eq(model.items[1].sender_type, "unknown")
	local manual = legacy_item("manual-example")
	manual.analysis = { state = "reply", pri = "P2", manual = true, summary = "", why = "", draft = "", task = { title = "", prompt = "" } }
	local item = restored({ version = 1, items = { manual } }).items[1]
	assert(item.analysis.judgment)
	t.eq(item.analysis.judgment.manual, true)
	t.eq(item.analysis.judgment.risk, "")
end)

t.test("v1 undated context is discarded without discarding durable analysis", function()
	local old = legacy_item("message-example")
	old.thread = { { id = "thread-example", sender = "Example", time = "03:00", content = "Undated context" } }
	old.thread_for_agent = { { content = "Obsolete cached clean context" } }
	old.session = "session-example"
	local model = restored({ version = 1, items = { old } })
	t.eq(model.items[1].thread, nil)
	t.eq(model.items[1].analysis.session, "session-example")
	t.eq(model.items[1].analysis.phase, "done")
	t.eq(old.thread[1].time, "03:00")
end)

t.test("task execution survives migration and v3 restore without restarting it", function()
	for _, phase in { "starting", "working", "waiting", "done", "closed" } do
		local old = legacy_item("task-example")
		old.analysis.state = "deep"
		old.triage, old.task_state = "doing", phase
		old.task_raw, old.result, old.task_new = "Raw task result", "Clean task result", 3
		local model = restored(snapshot.encode(restored({ version = 1, items = { old } })))
		local item = model.items[1]
		t.eq(item.disposition, "doing")
		assert(item.task)
		t.eq(item.task.phase, phase)
		t.eq(item.task.raw, "Raw task result")
		t.eq(item.task.result, "Clean task result")
		t.eq(item.task.new_messages, 3)
		t.eq(status.task_needs_me(item), true)
	end
end)

t.test("running analysis restores failed and an interrupted conversation gets one notice", function()
	local old = legacy_item("running-example")
	old.agent, old.session, old.reanalyze = "running", "session-example", true
	old.talk = { { me = true, text = "Question already sent" } }
	local stored = { version = 1, items = { old }, interrupted_chat = old.id }
	local model = restored(stored)
	local item = model.items[1]
	t.eq(item.analysis.phase, "failed")
	t.eq(item.analysis.session, "session-example")
	t.eq(item.analysis.gen, 0)
	t.eq(item.analysis.reanalyze, false)
	t.eq(item.analysis.error, "分析在重载时中断，未自动重试。按 r 手动重试。")
	t.eq(model.talking, nil)
	t.eq(#item.talk, 2)
	t.eq(item.talk[2].text, "对话在重载时中断，未自动续跑。请检查会话后重新发起。")
	t.eq(old.agent, "running")
	t.eq(#old.talk, 1)
	local again = restored(snapshot.encode(model))
	t.eq(again.items[1].analysis.phase, "failed")
	t.eq(#again.items[1].talk, 2)
end)

t.test("v3 running markers never turn into queued work", function()
	local model = model_with_item()
	local a = model.items[1].analysis
	a.phase, a.gen, a.reanalyze = "running", 42, true
	a.stage, a.resumed = "context", true
	model.talking = model.items[1].id
	local encoded = snapshot.encode(model)
	t.eq(encoded.items[1].analysis.phase, "running")
	t.eq(encoded.interrupted_chat, model.talking)
	local loaded = restored(encoded)
	t.eq(loaded.items[1].analysis.phase, "failed")
	t.eq(loaded.items[1].analysis.gen, 0)
	t.eq(loaded.items[1].analysis.stage, nil)
	t.eq(loaded.items[1].analysis.resumed, nil)
	t.eq(loaded.items[1].analysis.reanalyze, false)
	t.eq(loaded.talking, nil)
	for _, phase in { "queued", "failed", "done" } do
		a.phase = phase :: types.Phase
		t.eq(restored(snapshot.encode(model)).items[1].analysis.phase, phase)
	end
end)

t.test("v3 preserves user and navigation state with fresh config and detached values", function()
	local model = model_with_item()
	local item = model.items[1]
	item.revision = 7
	item.disposition, item.handoff_at, item.spoken = "handoff", 100, "User replied in chat"
	item.folded = { "folded-example" }
	item.edits = { reply = "", task = "Edited task" }
	item.talk = { { me = true, text = "Question" }, { text = "Answer" } }
	item.thread = { { id = "thread-example", sender = "Me", time = "2026-01-02 03:00", content = "Context", deleted = false, mine = true } }
	model.me, model.selected, model.person = "me-example", item.id, item.sender_id
	model.view, model.source, model.page, model.mode = "later", "dm", "settings", "command"
	model.command, model.command_cursor, model.draft_cursor = "Unsent question", 4, 2
	model.settings_cursor, model.field_cursor, model.dialog = "workspace", 3, item.id
	model.log = { { t = "03:04", who = "User", text = "Synthetic log" } }
	model.last_refresh, model.backlog_marked = 1000, true
	model.agenda = { events = { { summary = "Synthetic event" } } }
	model.chat_settings = { [item.chat_id] = { is_muted = false, is_mute_at_all = true } }
	model.cursors = { example = { token = "page-example", since = 50, paged = true, exhausted = false } }
	model.undo = { kind = "rule", id = item.id, chat_id = item.chat_id, previous = { mode = "manual", name = "Example group" } }
	model.images = { image_example = { path = "images/example.png" } }
	model.problem, model.runtime_warning = "Synthetic search error", "Synthetic warning"
	local encoded = snapshot.encode(model)
	local cfg = config()
	cfg.settings.agent_enabled = false
	local loaded = restored(encoded, cfg)
	local copy = loaded.items[1]
	t.eq(encoded.version, 3)
	t.eq(loaded.cfg, cfg)
	t.eq(loaded.cfg.settings.agent_enabled, false)
	t.eq(copy.revision, 7)
	t.eq(copy.disposition, "handoff")
	t.eq(copy.handoff_at, 100)
	t.eq(copy.spoken, "User replied in chat")
	t.eq(status.reply_text(copy), "")
	t.eq(status.task_text(copy), "Edited task")
	t.eq(loaded.selected, item.id)
	t.eq(loaded.person, item.sender_id)
	t.eq(loaded.me, "me-example")
	t.eq(loaded.view, "later")
	t.eq(loaded.source, "dm")
	t.eq(loaded.page, "settings")
	t.eq(loaded.mode, "command")
	t.eq(loaded.command, "Unsent question")
	t.eq(loaded.command_cursor, 4)
	t.eq(loaded.draft_cursor, 2)
	t.eq(loaded.settings_cursor, "workspace")
	t.eq(loaded.field_cursor, 3)
	t.eq(loaded.dialog, item.id)
	t.eq(loaded.last_refresh, 1000)
	t.eq(loaded.backlog_marked, true)
	t.eq(loaded.cursors.example.token, "page-example")
	t.eq(loaded.cursors.example.exhausted, false)
	assert(loaded.chat_settings)
	t.eq(loaded.chat_settings[item.chat_id].is_muted, false)
	t.eq(loaded.agenda.events[1].summary, "Synthetic event")
	assert(loaded.undo and loaded.undo.kind == "rule")
	t.eq(loaded.undo.previous.mode, "manual")
	t.eq(loaded.images.image_example.path, "images/example.png")
	t.eq(loaded.problem, "Synthetic search error")
	t.eq(loaded.runtime_warning, "Synthetic warning")
	item.folded[1], item.talk[1].text, model.agenda.events[1].summary = "changed", "changed", "changed"
	t.eq(encoded.items[1].folded[1], "folded-example")
	t.eq(encoded.items[1].talk[1].text, "Question")
	t.eq(encoded.agenda.events[1].summary, "Synthetic event")
	copy.folded[1], copy.talk[1].text, loaded.agenda.events[1].summary = "loaded change", "loaded change", "loaded change"
	t.eq(encoded.items[1].folded[1], "folded-example")
	t.eq(encoded.items[1].talk[1].text, "Question")
	t.eq(encoded.agenda.events[1].summary, "Synthetic event")
end)

t.test("v3 excludes handles, cached flags, request state and settings", function()
	local model: any = model_with_item()
	model.cx, model.poll, model.save_pending = function() end, function() end, true
	model.loading, model.loading_more, model.gen, model.wake_at = true, true, 99, 1234
	model.fetch_gen, model.chat_request, model.flash = 88, { cancel = function() end }, "Transient flash"
	model.images = {
		image_example = { path = "images/example.png", blob = function() end, pending = true, failed = true },
		pending_example = { pending = true, blob = function() end },
	}
	local item = model.items[1]
	item.hidden, item.no_agent, item.preparing, item.loading_thread, item.thread_gen = true, true, 7, true, 8
	item.preparation = { cancel = function() end }
	item.analysis.gen, item.analysis.stage, item.analysis.resumed, item.analysis.reanalyze = 9, "context", true, true
	local encoded = snapshot.encode(model)
	for _, field in { "cfg", "cx", "poll", "save_pending", "loading", "loading_more", "gen", "wake_at", "fetch_gen", "chat_request", "flash" } do
		t.eq(encoded[field], nil, field)
	end
	for _, field in { "hidden", "no_agent", "preparing", "loading_thread", "thread_gen", "preparation" } do
		t.eq(encoded.items[1][field], nil, field)
	end
	for _, field in { "gen", "stage", "resumed", "reanalyze" } do
		t.eq(encoded.items[1].analysis[field], nil, field)
	end
	t.eq(encoded.images.image_example.blob, nil)
	t.eq(encoded.images.image_example.pending, nil)
	t.eq(encoded.images.image_example.failed, nil)
	t.eq(encoded.images.pending_example, nil)
	local loaded = restored(encoded)
	t.eq(loaded.loading, false)
	t.eq(loaded.loading_more, false)
	t.eq(loaded.gen, 0)
	t.eq(loaded.items[1].hidden, false)
	t.eq(loaded.items[1].no_agent, false)
	t.eq(loaded.items[1].preparing, nil)
	t.eq(loaded.images.image_example.pending, nil)
end)

t.test("schema errors identify invalid durable fields instead of returning an empty model", function()
	local cases: { { path: string, corrupt: (any) -> () } } = {
		{ path = "items", corrupt = function(s) s.items = nil end },
		{ path = "items", corrupt = function(s) s.items = { [2] = s.items[1] } end },
		{ path = "items", corrupt = function(s) s.items.other = s.items[1] end },
		{ path = "items[1]", corrupt = function(s) s.items[1] = false end },
		{ path = "items[1].id", corrupt = function(s) s.items[1].id = "" end },
		{ path = "items[2].id", corrupt = function(s) s.items[2] = s.items[1] end },
		{ path = "folded", corrupt = function(s) s.items[1].folded = { 42 } end },
		{ path = "analysis", corrupt = function(s) s.items[1].analysis = nil end },
		{ path = "analysis.phase", corrupt = function(s) s.items[1].analysis.phase = "unknown" end },
		{ path = "judgment.kind", corrupt = function(s) s.items[1].analysis.judgment.kind = "unknown" end },
		{ path = "judgment.manual", corrupt = function(s) s.items[1].analysis.judgment.manual = "false" end },
		{ path = "disposition", corrupt = function(s) s.items[1].disposition = "sent" end },
		{ path = "revision", corrupt = function(s) s.items[1].revision = -1 end },
		{ path = "edits.reply", corrupt = function(s) s.items[1].edits.reply = 123 end },
		{ path = "talk", corrupt = function(s) s.items[1].talk = false end },
		{ path = "log", corrupt = function(s) s.log = false end },
		{ path = "images", corrupt = function(s) s.images = false end },
		{ path = "cursors", corrupt = function(s) s.cursors = false end },
		{ path = "images", corrupt = function(s) s.images = { example = { path = true } } end },
		{ path = "cursors", corrupt = function(s) s.cursors = { example = { paged = "true" } } end },
		{ path = "last_refresh", corrupt = function(s) s.last_refresh = 0 / 0 end },
		{ path = "command_cursor", corrupt = function(s) s.command_cursor = 0.5 end },
		{ path = "agenda", corrupt = function(s) s.agenda = function() end end },
	}
	for _, case in cases do
		local stored = packed()
		case.corrupt(stored)
		t.errors(function() snapshot.decode(stored, config()) end, case.path)
	end
end)

t.test("legacy false task fields are corrupt, not missing defaults", function()
	for _, field in { "task_state", "task_new" } do
		local old = legacy_item("task-example")
		old.triage, old[field] = "doing", false
		t.errors(function() snapshot.decode({ version = 1, items = { old } }, config()) end, ".task.")
	end
end)

t.test("nonserializable and cyclic dynamic data are explicit errors", function()
	local model = model_with_item()
	model.agenda = { callback = function() end }
	t.errors(function() snapshot.encode(model) end, "JSON data")
	local cycle: any = {}
	cycle.self = cycle
	local stored = packed()
	stored.agenda = cycle
	t.errors(function() snapshot.decode(stored, config()) end, "acyclic JSON data")
end)

t.test("old Markdown directory migrates once and current task text never routes", function()
	local stored = packed(); stored.version = 2
	stored.items[1].analysis.judgment.task.prompt = "执行 Workspace：/target\nInspect the change"
	stored.items[1].analysis.judgment.task.workspace = nil
	local model = restored(stored)
	t.eq(status.task_workspace(model.items[1]), "/target")
	t.eq(status.task_text(model.items[1]), "Inspect the change")
	model.items[1].edits.task = "执行 Workspace：/not-a-route\nBusiness text"
	model.items[1].edits.workspace = ""
	local current = restored(snapshot.encode(model))
	t.eq(status.task_workspace(current.items[1]), "")
	t.eq(status.task_text(current.items[1]), "执行 Workspace：/not-a-route\nBusiness text")
	t.eq(stored.items[1].analysis.judgment.task.prompt, "执行 Workspace：/target\nInspect the change")
end)

t.test("ambiguous historical routing requires visible directory reconfirmation", function()
	for _, prefix in { "执行 Workspace：", "附加仓库：/old" } do
		local stored = packed(); stored.version = 2
		local j = stored.items[1].analysis.judgment
		j.kind, j.task.prompt, j.task.workspace = "deep", prefix .. "\nInspect", nil
		local model = restored(stored)
		local item = model.items[1]
		t.eq(status.task_workspace(item), ""); t.eq(item.task_workspace_unconfirmed, true)
		t.eq(status.needs_confirm(item), true)
		t.eq(status.task_text(item), "Inspect")
		local next_model = restored(snapshot.encode(model))
		t.eq(next_model.items[1].task_workspace_unconfirmed, true)
	end
end)

t.done()

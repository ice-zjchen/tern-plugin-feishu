--!strict
local t = require("./t")
local types = require("../src/core/types")
local matter = require("../src/core/matter")
local status = require("../src/core/status")
local views = require("../src/core/views")
local update = require("../src/core/update")
local snapshot = require("../src/core/snapshot")
local schema = require("../src/shared/schema")

type Model = types.Model
type Matter = types.Matter
local function model(): Model
	local settings: { [string]: any } = {}
	for _, f in schema.FIELDS do settings[f.id] = f.default end
	settings.agent_enabled = false
	return snapshot.empty({ settings = settings, rules = {}, stars = {}, now = 1794000000 })
end
local function message(id: string, clock: string?, content: string?): any
	return { message_id = id, chat_id = "chat", chat_name = "研发", chat_type = "group", create_time = clock or "2026-11-01 10:00",
		content = content or "请排查", sender = { id = "sender", name = "甲", sender_type = "user" }, mentions = { { id = "me" } },
		message_app_link = "https://applink.feishu.cn/client/chat/open?chat=x" }
end
local function add(s: Model, id: string, kind: types.Kind?): Matter
	local m = matter.make(message(id), s.cfg.now)
	m.mention, m.via, m.analysis.settle_at = true, "@我", nil
	if kind then
		local j = status.manual_judgment(); j.kind, j.manual, j.summary = kind, false, id
		j.task = { prompt = "分析仓库", title = "任务", workspace = "" }
		j.draft = "我来看看"
		m.analysis.phase, m.analysis.judgment = "done", j
	end
	table.insert(s.items, m)
	s.selected = s.selected or id
	return m
end
local function action(s: Model, name: string, value: any?): { update.Effect }
	local out = update.apply(s, { type = "action", name = name, value = value })
	return out
end
local function effects(out: { update.Effect }, kind: string): { any }
	local result = {}
	for _, e in out do if e.type == kind then table.insert(result, e) end end
	return result
end

t.test("views and tab share exclusive pending/doing/later counts", function()
	local s = model()
	local p = add(s, "pending", "deep")
	local doing = add(s, "doing", "deep"); doing.disposition = "doing"; doing.task = { phase = "working", new_messages = 0 }
	local waiting = add(s, "waiting", "deep"); waiting.disposition = "doing"; waiting.task = { phase = "waiting", new_messages = 0 }
	local later = add(s, "later", "reply"); later.disposition = "snoozed"
	local archived = add(s, "archived", "reply"); archived.disposition = "archived"
	local hidden = add(s, "hidden", "deep"); hidden.hidden = true
	local c = views.counts(s.items)
	t.eq(c.pending, 2); t.eq(c.doing, 1); t.eq(c.later, 1); t.eq(c.done, 1)
	t.eq(views.tab_name(s.items, false, nil), "飞书｜待处理2·处理中1·稍后1")
	t.eq(status.next_action(p).key, "task")
end)

t.test("risk confirmation cannot be bypassed by a key action", function()
	local s = model(); local m = add(s, "risk", "deep")
	local judgment = m.analysis.judgment :: types.Judgment
	judgment.risk = "通过发布单"
	t.eq(#effects(action(s, "primary"), "prepare"), 0)
	t.eq(m.preparing, nil)
	action(s, "confirm-task")
	t.eq(m.preparing ~= nil, true)
	t.eq(status.next_action(m).key, "none")
end)

t.test("new judgment pending prevents copy, edit and task start", function()
	local s = model(); local m = add(s, "stale", "deep")
	m.analysis.phase = "queued"
	t.eq(status.stale(m), true)
	t.eq(status.can_edit(m), false)
	t.eq(status.next_action(m).key, "none")
	t.eq(#effects(action(s, "copy"), "copy"), 0)
	t.eq(#effects(action(s, "primary"), "prepare"), 0)
end)

t.test("edited task while preparing invalidates launch", function()
	local s = model(); local m = add(s, "task", "deep"); m.thread = {}
	local prepared = effects(action(s, "primary"), "prepare")[1]
	t.eq(prepared.task, "分析仓库")
	update.apply(s, { type = "focus", mode = "draft" })
	update.apply(s, { type = "field-key", key = { name = "paste", text = "，只读" } })
	local out = update.apply(s, { type = "prepared", id = m.id, gen = prepared.gen, prompt = "old prompt" })
	t.eq(#effects(out, "write-task"), 0)
	t.eq(m.disposition, nil); t.eq(m.preparing, nil)
end)

t.test("prepare callback from an older attempt cannot open a task", function()
	local s = model(); local m = add(s, "task", "deep"); m.thread = {}
	local req = effects(action(s, "primary"), "prepare")[1]
	local stale = update.apply(s, { type = "prepared", id = m.id, gen = req.gen + 1, prompt = "stale" })
	t.eq(#effects(stale, "write-task"), 0)
	local out = update.apply(s, { type = "prepared", id = m.id, gen = req.gen, prompt = "confirmed" })
	t.eq(#effects(out, "write-task"), 1); t.eq(m.disposition, "doing")
end)

t.test("manual task opens without starting analysis or requiring history", function()
	local s = model(); local m = add(s, "manual", nil)
	local out = action(s, "open-task")
	t.eq(#effects(out, "thread"), 0)
	t.eq(#effects(out, "analyze"), 0)
	local req = effects(out, "prepare")[1]; t.eq(req.task, nil)
	update.apply(s, { type = "prepared", id = m.id, gen = req.gen, prompt = "wait for user" })
	t.eq(m.disposition, "doing")
end)

t.test("task idle with a reply becomes a draft, not automatic completion", function()
	local s = model(); local m = add(s, "task", "deep")
	m.disposition, m.task = "doing", { phase = "working", new_messages = 0, request_id = 1, revision = 0,
		task_text = "分析仓库", workspace = "/repo", default_workspace = "/default" }
	update.apply(s, { type = "tasks", tasks = { task = { version = 2, matter_id = m.id, revision = 0,
		request_id = 1, state = "done", result = "检查完毕\n<reply>已确认原因</reply>" } } })
	t.eq(m.disposition, nil)
	t.eq(status.kind(m), "reply"); t.eq(status.reply_text(m), "已确认原因")
	t.eq(status.settled(m), false)
end)

t.test("task round ending without a reply stays pending user confirmation", function()
	local s = model(); local m = add(s, "task", "deep")
	m.disposition, m.task = "doing", { phase = "working", new_messages = 0, request_id = 1, revision = 0,
		task_text = "分析仓库", workspace = "/repo", default_workspace = "/default" }
	update.apply(s, { type = "tasks", tasks = { task = { version = 2, matter_id = m.id, revision = 0,
		request_id = 1, state = "done", result = "已检查，待你核对" } } })
	t.eq(m.disposition, "doing"); t.eq(status.task_needs_me(m), true)
	t.eq(views.counts(s.items).pending, 1); t.eq(views.counts(s.items).doing, 0)
end)

t.test("possible reply is not settled before user confirmation", function()
	local s = model(); local m = add(s, "reply", "reply")
	action(s, "primary")
	t.eq(m.disposition, "handoff")
	update.apply(s, { type = "spoken", id = m.id, revision = m.revision, text = "我回答过了" })
	t.eq(status.settled(m), false)
	action(s, "view", "doing")
	action(s, "confirm-reply"); t.eq(m.disposition, "replied")
	action(s, "undo"); t.eq(m.disposition, "handoff"); t.eq(m.spoken, nil)
end)

t.test("folded new message reopens archive and invalidates its analysis", function()
	local s = model(); s.me = "me"
	local m = add(s, "old", "deep"); m.disposition = "archived"
	local out = {}
	matter.merge(s, { { messages = { message("new", "2026-11-01 10:05") }, mention = true } }, {}, out)
	t.eq(#s.items, 1); t.eq(m.latest_id, "new"); t.eq(m.disposition, nil)
	t.eq(m.analysis.phase, "queued"); t.eq(m.revision, 1)
	t.eq(#effects(out, "record"), 1)
end)

t.test("older page reconstructs a mention chain without reopening it", function()
	local s = model(); s.me = "me"
	local m = add(s, "new", "deep"); m.time = "2026-11-01 10:05"; m.disposition = "archived"
	matter.merge(s, { { messages = { message("old", "2026-11-01 10:00") }, mention = true } }, { old = { s = "archived" } }, {})
	t.eq(#s.items, 1); t.eq(m.disposition, "archived"); t.eq(m.content, "请排查")
	t.eq(m.analysis.phase, "done")
end)

t.test("message arriving during task is counted, never sent to the task", function()
	local s = model(); s.me = "me"
	local m = add(s, "task", "deep"); m.disposition = "doing"; m.task = { phase = "working", new_messages = 0 }
	local out = {}
	matter.merge(s, { { messages = { message("new", "2026-11-01 10:05") }, mention = true } }, {}, out)
	t.eq((m.task :: types.Task).new_messages, 1); t.eq(status.task_needs_me(m), true)
	t.eq(#effects(out, "write-task"), 0)
end)

t.test("unknown muted-chat preferences hide chat and its analysis context", function()
	local s = model(); s.cfg.settings.hide_muted = true
	local m = add(s, "unknown", "deep")
	matter.apply_rules(s)
	t.eq(m.hidden, true); t.eq(views.counts(s.items).pending, 0)
	s.chat_settings = { chat = { is_muted = false, is_mute_at_all = false } }
	matter.apply_rules(s); t.eq(m.hidden, false)
end)

t.test("AI concurrency slots come from running phases and are returned on failure", function()
	local s = model(); s.cfg.settings.agent_enabled = true; s.cfg.settings.concurrency = 1
	local a = add(s, "a", nil); local b = add(s, "b", nil)
	update.apply(s, { type = "init" })
	t.eq(a.analysis.phase, "running"); t.eq(b.analysis.phase, "queued")
	update.apply(s, { type = "analyzed", id = a.id, gen = a.analysis.gen, error = "unavailable" })
	t.eq(a.analysis.phase, "failed"); t.eq(b.analysis.phase, "running")
end)

t.test("stale analysis response does not replace current judgment", function()
	local s = model(); local m = add(s, "analysis", "deep")
	m.analysis.phase, m.analysis.gen, m.analysis.stage = "running", 10, "model"
	local before = m.analysis.judgment
	update.apply(s, { type = "analyzed", id = m.id, gen = 9, judgment = status.manual_judgment() })
	t.eq(m.analysis.judgment, before); t.eq(m.analysis.phase, "running")
end)

t.test("rewritten task clears an old risk warning", function()
	local s = model(); local m = add(s, "change", "deep"); m.thread = {}
	(m.analysis.judgment :: types.Judgment).risk = "发布"
	s.command = "改为只读"
	local req = effects(action(s, "run-command"), "converse")[1]
	update.apply(s, { type = "conversed", id = m.id, gen = req.gen, reply = "已修改", change = { task = "只查询状态", risk = "" } })
	t.eq((m.analysis.judgment :: types.Judgment).risk, "")
	t.eq(status.needs_confirm(m), false)
end)

t.test("restoring a loaded queue and syncing tasks does not replay analysis", function()
	local s = model(); s.loaded = true; s.cfg.settings.agent_enabled = true
	local m = add(s, "old-queued", nil)
	local out = update.apply(s, { type = "init" })
	t.eq(m.analysis.phase, "queued")
	t.eq(#effects(out, "analyze"), 0)
	update.apply(s, { type = "tasks", tasks = {} })
	t.eq(m.analysis.phase, "queued")
	update.apply(s, { type = "select", id = m.id })
	t.eq(m.analysis.phase, "running")
end)

t.test("double-clicking retry cannot start the same analysis twice", function()
	local s = model(); s.cfg.settings.agent_enabled = true
	local m = add(s, "retry", nil); m.analysis.phase = "failed"
	action(s, "retry")
	local first = m.analysis.gen
	t.eq(m.analysis.phase, "running")
	local second = action(s, "retry")
	t.eq(m.analysis.gen, first)
	t.eq(#effects(second, "analyze"), 0)
	t.eq(#effects(second, "thread"), 0)
end)

t.test("repeated private-chat refresh does not duplicate message identities", function()
	local s = model(); s.me = "me"
	local first, second = message("old", "2026-11-01 10:00"), message("new", "2026-11-01 10:05")
	first.chat_type, second.chat_type = "p2p", "p2p"
	local sources = { { messages = { first, second }, mention = false } }
	matter.merge(s, sources, {}, {})
	matter.merge(s, sources, {}, {})
	matter.merge(s, sources, {}, {})
	t.eq(#s.items, 1); t.eq(s.items[1].id, "new")
	t.eq(#status.ids(s.items[1]), 2)
	t.eq(s.items[1].folded[1], "old")
end)

t.test("snapshot restoration normalizes repeated references without losing messages", function()
	local s = model(); local m = add(s, "main", "reply")
	m.folded = { "first", "first", "main", "second", "first" }
	local restored = snapshot.decode(snapshot.encode(s), s.cfg)
	assert(restored)
	local ids = status.ids(restored.items[1])
	t.eq(#ids, 3)
	t.eq(ids[1], "main"); t.eq(ids[2], "first"); t.eq(ids[3], "second")
end)

t.test("workspace-only corrections are visible state and invalidate preparation", function()
	local s = model(); local m = add(s, "workspace", "deep"); m.thread = {}
	s.command = "改在 /target 执行"
	local chat = effects(action(s, "run-command"), "converse")[1]
	local out = update.apply(s, { type = "conversed", id = m.id, gen = chat.gen, reply = "已改目录", change = { workspace = "/target" } })
	t.eq(status.task_workspace(m), "/target"); t.eq(status.task_text(m), "分析仓库")
	local correction = effects(out, "workbench-event")[1].event
	t.eq(correction.type, "workbench_chat"); t.eq(correction.data.user_said, "改在 /target 执行")
	t.eq(correction.data.content, nil)
	local req = effects(action(s, "primary"), "prepare")[1]
	t.eq(m.preparation.workspace, "/target")
	s.command = "改回默认目录"
	chat = effects(action(s, "run-command"), "converse")[1]
	update.apply(s, { type = "conversed", id = m.id, gen = chat.gen, reply = "已改", change = { workspace = "" } })
	t.eq(status.task_workspace(m), "")
	out = update.apply(s, { type = "prepared", id = m.id, gen = req.gen, prompt = "outdated" })
	t.eq(#effects(out, "write-task"), 0)
end)

t.test("structured directory survives task text editing and launch awaits durable confirmation", function()
	local s = model(); local m = add(s, "explicit", "deep"); m.thread = {}
	m.edits.workspace = "/target"
	m.edits.task = "执行 Workspace：/not-a-route\n只读排查"
	local req = effects(action(s, "primary"), "prepare")[1]
	local out = update.apply(s, { type = "prepared", id = m.id, gen = req.gen, prompt = "confirmed prompt" })
	local write = effects(out, "write-task")[1]
	t.eq(write.workspace, "/target"); t.eq(write.task_text, m.edits.task)
	t.eq(write.revision, 0); t.eq(#effects(out, "open-task"), 0)
	out = update.apply(s, { type = "task-written", id = m.id, revision = 0, request_id = 7, workspace = "/target", default_workspace = "/workflow" })
	t.eq(#effects(out, "open-task"), 1); t.eq((m.task :: types.Task).request_id, 7)
	local restored = snapshot.decode(snapshot.encode(s), s.cfg)
	assert(restored)
	t.eq((restored.items[1].task :: types.Task).default_workspace, "/workflow")
end)

t.test("task result events bind only current request and never replay on polling", function()
	local s = model(); local m = add(s, "result", "deep")
	m.disposition, m.task = "doing", { phase = "working", new_messages = 0, request_id = 7, revision = 2,
		task_text = "Confirmed business task", workspace = "/target", default_workspace = "/workflow" }
	local state = { version = 2, matter_id = m.id, revision = 2, request_id = 6, state = "done", result = "Stale result" }
	local out = update.apply(s, { type = "tasks", tasks = { result = state } })
	t.eq((m.task :: types.Task).phase, "working"); t.eq(#effects(out, "workbench-event"), 0)
	state.request_id, state.result = 7, "Actual result"
	out = update.apply(s, { type = "tasks", tasks = { result = state } })
	local result = effects(out, "workbench-event")[1].event
	t.eq(result.type, "task_result"); t.eq(result.request_id, 7); t.eq(result.revision, 2)
	t.eq(result.workspace, "/workflow"); t.eq(result.data.execution_workspace, "/target")
	t.eq(result.data.task, "Confirmed business task"); t.eq(result.data.final, "Actual result")
	out = update.apply(s, { type = "tasks", tasks = { result = state } })
	t.eq(#effects(out, "workbench-event"), 0)
end)

t.test("accepted analysis emits judgment summaries without original source messages", function()
	local s = model(); local m = add(s, "analysis-event", "deep")
	m.content, m.thread = "Third party raw message", { { id = "raw", content = "Raw thread", sender = "Other", time = "", deleted = false, mine = false } }
	m.analysis.phase, m.analysis.gen = "running", 9
	local j = status.manual_judgment(); j.kind, j.manual, j.summary = "deep", false, "Decision summary"
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = 9, judgment = j, session = "session", run = { cwd = "/workflow" } })
	local event = effects(out, "workbench-event")[1].event
	t.eq(event.type, "analysis"); t.eq(event.workspace, "/workflow"); t.eq(event.session, "session")
	t.eq(event.data.result.summary, "Decision summary"); t.eq(event.data.content, nil); t.eq(event.data.thread, nil)
	out = update.apply(s, { type = "analyzed", id = m.id, gen = 9, judgment = j })
	t.eq(#effects(out, "workbench-event"), 0)
end)

t.test("chat events use the run directory even when settings change mid-turn", function()
	local s = model(); local m = add(s, "chat-workspace", "deep"); m.thread = {}
	s.cfg.settings.workspace, s.command = "/original", "Only inspect"
	local req = effects(action(s, "run-command"), "converse")[1]
	s.cfg.settings.workspace = "/changed"
	local out = update.apply(s, { type = "conversed", id = m.id, gen = req.gen, reply = "Updated",
		change = { task = "Only inspect", risk = "" }, run = { cwd = "/original" } })
	local event = effects(out, "workbench-event")[1].event
	t.eq(event.workspace, "/original")
end)

t.test("default directory changes during preparation require new confirmation", function()
	local s = model(); local m = add(s, "directory-change", "deep"); m.thread = {}
	s.cfg.settings.workspace = "/original"
	local req = effects(action(s, "primary"), "prepare")[1]
	s.cfg.settings.workspace = "/changed"
	local out = update.apply(s, { type = "prepared", id = m.id, gen = req.gen, prompt = "Old workspace prompt" })
	t.eq(#effects(out, "write-task"), 0); t.eq(m.disposition, nil)
end)

t.test("historical task results stay read-only and ambiguous restarts require reconfirmation", function()
	local s = model(); local m = add(s, "historical", "deep")
	m.disposition, m.task = "doing", { phase = "working", new_messages = 0 }
	local out = update.apply(s, { type = "tasks", tasks = { historical = { request_id = 0, state = "done", result = "Old result" } } })
	t.eq(#effects(out, "workbench-event"), 0); t.eq((m.task :: types.Task).result, "Old result")
	m.task = { phase = "closed", new_messages = 0 }
	m.task_workspace_unconfirmed = true
	out = action(s, "primary")
	t.eq(#effects(out, "prepare"), 0); t.eq(m.disposition, nil)
	t.eq(status.needs_confirm(m), true)
end)

t.done()

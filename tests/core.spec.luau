--!strict
local t = require("./t")
local types = require("../src/core/types")
local matter = require("../src/core/matter")
local status = require("../src/core/status")
local views = require("../src/core/views")
local update = require("../src/core/update")
local snapshot = require("../src/core/snapshot")
local input = require("../src/ui/input")
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
local function cache(m: Matter, prompt: string?)
	m.context = { gen = 0, revision = m.revision, task = status.task_text(m), phase = "ready",
		prompt = prompt or "cached task prompt", needs = { plan = "none",
			materials = { choice = "not_required" }, discussion = { choice = "not_required" } } }
end
local function context_ready(s: Model, req: any, prompt: string?): { update.Effect }
	local out = update.apply(s, { type = "context-prepared", id = req.id, gen = req.gen, revision = req.revision,
		prompt = prompt or "cached task prompt", needs = { plan = "none",
			materials = { choice = "not_required" }, discussion = { choice = "not_required" } } })
	return out
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
	cache(p)
	t.eq(status.next_action(p).key, "task")
end)

t.test("bot aggregation does not depend on analysis phase", function()
	local s = model()
	for _, phase in { "queued", "running", "failed", "done" } do
		local m = add(s, "analysis-" .. phase)
		m.bot_profile, m.analysis.phase = "dedicated", phase :: types.Phase
	end
	t.eq(#views.visible(s.items, { view = "bot", source = "all", bot_profile = "dedicated" }), 4)
	t.eq(views.counts(s.items, "dedicated").bot, 4)
end)

t.test("bot source includes every disposition and task state only for the current nonempty profile", function()
	local s = model(); s.cfg.settings.bot_profile = "dedicated"
	local dispositions: { types.Disposition } = { "handoff", "snoozed", "doing", "archived", "replied" }
	local open = add(s, "bot-open", "reply"); open.bot_profile = "dedicated"
	for _, disposition in dispositions do
		local m = add(s, "bot-" .. disposition, "deep")
		m.bot_profile, m.disposition, m.hidden = "dedicated", disposition, true
	end
	for _, phase in { "starting", "working", "waiting", "done", "closed" } do
		local m = add(s, "task-" .. phase, "deep")
		m.bot_profile, m.disposition = "dedicated", "doing"
		m.task = { phase = phase :: types.TaskPhase, new_messages = 0 }
	end
	local ordinary = add(s, "ordinary", "reply"); ordinary.instruction = "not an authenticated command"
	local other = add(s, "other-profile", "reply"); other.bot_profile = "other"
	local shown = views.visible(s.items, { view = "bot", source = "dm", person = "unrelated", bot_profile = "dedicated" })
	t.eq(#shown, 11); t.eq(views.counts(s.items, "dedicated").bot, 11)
	for _, m in shown do t.eq(m.bot_profile, "dedicated") end
	t.eq(#views.visible(s.items, { view = "bot", source = "all" }), 0)
	t.eq(#views.visible(s.items, { view = "bot", source = "all", bot_profile = "" }), 0)
	t.eq(views.counts(s.items).bot, 0)
end)

t.test("bot view uses the actual app name and clears filters without searching history", function()
	local s = model(); s.loaded = true; s.cfg.settings.bot_profile = "dedicated"
	local m = add(s, "bot-source", "reply"); m.bot_profile = "dedicated"
	s.source, s.person, s.page = "dm", "another-person", "settings"
	s.cfg.bot_name = "实际应用名"
	local out = action(s, "view", "bot")
	t.eq(s.page, nil); t.eq(s.source, "all"); t.eq(s.person, nil); t.eq(s.selected, m.id)
	for _, effect in out do t.eq(effect.type == "history-search" or effect.type == "fetch", false) end
	local facts = update.facts(s)
	t.eq(#facts.queue, 1)
	local definition: any = nil
	for _, view in facts.views do if view.id == "bot" then definition = view end end
	t.eq(definition.label, "@实际应用名"); t.eq(definition.count, 1)
	t.eq(views.bot_label(nil), "@机器人"); t.eq(views.bot_label(""), "@机器人")
	t.eq(views.bot_label("  "), "@机器人")
	action(s, "source", "mention"); action(s, "person", "other")
	t.eq(s.source, "all"); t.eq(s.person, nil)
end)

t.test("profile changes cannot keep another bot's detail or dialog selected", function()
	local s = model(); s.cfg.settings.bot_profile = "first"; s.view = "bot"
	local first = add(s, "first-profile", "reply"); first.bot_profile = "first"
	local second = add(s, "second-profile", "reply"); second.bot_profile = "second"
	s.selected, s.dialog, s.reading = first.id, first.id, true
	update.apply(s, { type = "setting", setting = "bot_profile", value = "second" })
	t.eq(s.selected, second.id); t.eq(s.dialog, nil); t.eq(s.reading, nil)
	t.eq(update.facts(s).item.id, second.id); t.eq(#update.facts(s).queue, 1)
	update.apply(s, { type = "select", id = first.id, open = true })
	t.eq(s.selected, second.id)
	s.selected, s.dialog = first.id, first.id
	t.eq(update.facts(s).item, nil); t.eq(update.facts(s).dialog_item, nil)
	update.apply(s, { type = "continue" })
	t.eq(s.selected, second.id); t.eq(s.dialog, nil)
	update.apply(s, { type = "setting", setting = "bot_profile", value = "" })
	t.eq(s.selected, nil); t.eq(update.facts(s).item, nil); t.eq(#update.facts(s).queue, 0)
end)

t.test("commands associate existing tasks without duplication and survive an ordinary @me refresh and reload", function()
	local s = model(); s.cfg.settings.bot_profile = "dedicated"; s.me = "me"
	local m = add(s, "existing-task", "deep")
	m.disposition, m.task = "doing", { phase = "working", new_messages = 0, result = "已有进展" }
	local revision, task = m.revision, m.task
	local out = update.apply(s, { type = "bot-message", bot_profile = "dedicated", message = message(m.id), instruction = "检查进度" })
	t.eq(m.bot_profile, "dedicated"); t.eq(m.instruction, "检查进度")
	t.eq(m.revision, revision); t.eq(m.task, task); t.eq(m.disposition, "doing")
	t.eq(#effects(out, "write-task"), 0); t.eq(#effects(out, "thread"), 0)
	matter.merge(s, { { mention = true, messages = { message(m.id) } } }, {}, {})
	t.eq(m.via, "@我"); t.eq(m.bot_profile, "dedicated")
	s.view = "bot"
	local loaded = snapshot.decode(snapshot.encode(s), s.cfg) :: Model
	local restored = update.facts(loaded)
	t.eq(#restored.queue, 1); t.eq(restored.queue[1].instruction, "检查进度")
	t.eq(restored.queue[1].task.result, "已有进展"); t.eq(restored.queue[1].bot_profile, "dedicated")
end)

t.test("with background off and no workbench open, nothing new is fetched or analyzed", function()
	local s = model(); s.loaded = true
	s.cfg.settings.background, s.cfg.settings.agent_enabled = false, true
	s.last_refresh = s.cfg.now - 3600
	local m = add(s, "queued"); m.analysis.phase = "queued"
	s.queue_enabled = true
	local hidden_out = update.apply(s, { type = "tick" })
	t.eq(#effects(hidden_out, "fetch"), 0); t.eq(m.analysis.phase, "queued")
	s.cfg.visible = true
	local shown_out = update.apply(s, { type = "tick" })
	t.eq(#effects(shown_out, "fetch"), 1); t.eq(m.analysis.phase, "running")
	s.cfg.visible, s.cfg.settings.background, s.loading = false, true, false
	s.last_refresh = s.cfg.now - 3600
	t.eq(#effects(update.apply(s, { type = "tick" }), "fetch"), 1)
end)

t.test("headless deep contexts respect background pause and resume when the card becomes visible", function()
	local s = model(); s.loaded = true; s.cfg.settings.background = false
	local m = add(s, "paused-context", "deep"); m.thread = {}
	t.eq(#effects(update.apply(s, { type = "init" }), "context"), 0); t.eq(m.context, nil)
	m.analysis.phase, m.analysis.stage, m.analysis.gen = "running", "model", 7
	local j = status.manual_judgment(); j.kind, j.manual = "deep", false
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = 7, judgment = j })
	t.eq(#effects(out, "context"), 0); t.eq(m.context, nil)
	s.cfg.visible = true
	out = update.apply(s, { type = "select", id = m.id })
	t.eq(#effects(out, "context"), 1)
	local pending = add(s, "paused-thread", "deep")
	out = update.apply(s, { type = "select", id = pending.id })
	local thread = effects(out, "thread")[1]
	s.cfg.visible = false
	out = update.apply(s, { type = "thread", id = pending.id, gen = thread.gen, latest = pending.id, messages = {} })
	t.eq(#effects(out, "context"), 0); t.eq((pending.context :: types.TaskContext).phase, "thread")
	s.cfg.visible = true
	t.eq(#effects(update.apply(s, { type = "init" }), "context"), 1)
end)

t.test("a stopped analysis waits for retry and is not requeued by new messages", function()
	local s = model()
	local m = add(s, "stop"); m.analysis.phase, m.analysis.stage, m.analysis.gen = "running", "model", 7
	m.analysis.reanalyze = true
	local out = action(s, "stop")
	t.eq(#effects(out, "stop-analysis"), 1); t.eq(m.analysis.phase, "running")
	update.apply(s, { type = "analyzed", id = m.id, gen = 7, error = "AI 程序退出码 -1" })
	t.eq(m.analysis.phase, "failed"); t.eq(m.analysis.reanalyze, false)
	t.eq(string.find(m.analysis.error :: string, "手动停止", 1, true) ~= nil, true)
	local loading = add(s, "loading"); loading.analysis.phase, loading.analysis.stage = "running", "thread"
	s.selected = loading.id
	t.eq(#effects(action(s, "stop"), "stop-analysis"), 0); t.eq(loading.analysis.phase, "failed")
	s.selected = m.id; action(s, "retry"); t.eq(m.analysis.phase ~= "failed", true)
end)

t.test("stopping all signals every running model turn and pauses automatic analysis", function()
	local s = model(); s.cfg.settings.agent_enabled = true
	local one = add(s, "one"); one.analysis.phase, one.analysis.stage = "running", "model"
	local two = add(s, "two"); two.analysis.phase, two.analysis.stage = "running", "model"
	local out = action(s, "stop-all")
	t.eq(#effects(out, "stop-analysis"), 2); t.eq(s.cfg.settings.agent_enabled, false)
end)

t.test("only the bound owner's group @ commands the bot; binding needs the shown code", function()
	local s = model(); s.bot_code = "4821"
	s.cfg.bot_id = "ou_bot"
	local function bot(e: any)
		e.type = e.type or "im.message.receive_v1"
		e.sender_type = e.sender_type or "user"
		if e.mentions == nil then e.mentions = { { id = "ou_bot" } } end
		return update.apply(s, { type = "bot-event", event = e })
	end
	t.eq(#effects(bot({ message_id = "om_p1", sender_id = "ou_other", chat_type = "p2p", content = "绑定 1111" }), "bot-bind"), 0)
	t.eq(#effects(bot({ message_id = "om_p2", sender_id = "ou_me", chat_type = "p2p", content = " 绑定 4821 " }), "bot-bind"), 1)
	t.eq(s.bot_code, nil)
	s.cfg.bot_owner = "ou_me"
	t.eq(#effects(bot({ message_id = "om_g1", sender_id = "ou_other", chat_type = "group", content = "@bot 处理" }), "bot-fetch"), 0)
	local fetch = effects(bot({ message_id = "om_g2", sender_id = "ou_me", chat_type = "group", content = "@bot 排查", reply_to = "om_target" }), "bot-fetch")
	t.eq(#fetch, 1); t.eq(fetch[1].target, "om_target"); t.eq(fetch[1].instruction, "@bot 排查")
	t.eq(#effects(bot({ message_id = "om_g2", sender_id = "ou_me", chat_type = "group", content = "@bot 排查", reply_to = "om_target" }), "bot-fetch"), 0)
	local own = effects(bot({ message_id = "om_g3", sender_id = "ou_me", chat_type = "group", content = "@bot 看下这个" }), "bot-fetch")
	t.eq(own[1].target, "om_g3")
	t.eq(#effects(bot({ message_id = "om_plain", sender_id = "ou_me", chat_type = "group", content = "普通聊天", mentions = {} }), "bot-fetch"), 0)
	t.eq(#effects(bot({ message_id = "om_otherbot", sender_id = "ou_me", chat_type = "group", content = "@bot 处理", mentions = { { id = "ou_different_bot" } } }), "bot-fetch"), 0)
	t.eq(#effects(bot({ message_id = "om_bot_sender", sender_id = "ou_me", sender_type = "bot", chat_type = "group", content = "处理" }), "bot-fetch"), 0)
	local restored = snapshot.decode(snapshot.encode(s), s.cfg) :: Model
	t.eq(#effects(update.apply(restored, { type = "bot-event", event = { type = "im.message.receive_v1", sender_type = "user",
		message_id = "om_g2", sender_id = "ou_me", chat_type = "group", content = "重投", mentions = { { id = "ou_bot" } } } }), "bot-fetch"), 0)
end)

t.test("a commanded message is analyzed at once despite filters and pauses, and a deep result starts its task", function()
	local s = model(); s.loaded = true
	s.cfg.settings.bot_profile = "dedicated"
	s.cfg.settings.agent_enabled, s.cfg.settings.background, s.cfg.settings.concurrency = false, false, 1
	s.cfg.rules.chat = { mode = "hide", name = "研发" }
	local busy = add(s, "busy"); busy.analysis.phase, busy.analysis.stage = "running", "model"
	local out = update.apply(s, { type = "bot-message", bot_profile = "dedicated", message = message("om_cmd"), instruction = "@bot 排查一下" })
	local m = matter.find(s, "om_cmd") :: Matter
	t.eq(m.hidden, false); t.eq(m.analysis.phase, "running"); t.eq(#effects(out, "thread"), 1)
	t.eq(m.bot_profile, "dedicated")
	m.thread = {}; m.analysis.stage = "model"
	local j = status.manual_judgment(); j.kind, j.manual, j.task = "deep", false, { title = "排查", prompt = "排查报错", workspace = "" }
	local assessed = effects(update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j }), "context")[1]
	t.eq(m.preparing ~= nil, true); t.eq(m.preparation.auto, true)
	t.eq((m.context :: types.TaskContext).phase, "model"); t.eq(m.disposition, nil)
	local launched = context_ready(s, assessed, "机器人任务")
	t.eq(effects(launched, "write-task")[1].prompt, "机器人任务")
	t.eq(#effects(launched, "prepare"), 0); t.eq(#effects(launched, "context"), 0)
	t.eq(m.disposition, "doing")
	local written = update.apply(s, { type = "task-written", id = m.id, revision = (m.task :: types.Task).revision, request_id = 3, workspace = "/w", default_workspace = "/w" })
	t.eq(#effects(written, "open-task"), 0)
end)

t.test("a commanded risky deep result starts preparation without a workbench confirmation", function()
	local s = model(); s.loaded = true
	update.apply(s, { type = "bot-message", message = message("om_risk"), instruction = "@bot 发布" })
	local m = matter.find(s, "om_risk") :: Matter
	m.thread = {}; m.analysis.stage = "model"
	local j = status.manual_judgment(); j.kind, j.manual, j.risk = "deep", false, "通过发布单"
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j })
	t.eq(m.preparing ~= nil, true); t.eq(m.preparation.auto, true); t.eq(m.disposition, nil)
	out = context_ready(s, effects(out, "context")[1])
	t.eq(effects(out, "write-task")[1].auto, true); t.eq(m.disposition, "doing")
end)

t.test("stopping a commanded analysis prevents automatic task launch even if the result races the stop", function()
	local s = model()
	update.apply(s, { type = "bot-message", message = message("om_stop_auto"), instruction = "排查" })
	local m = matter.find(s, "om_stop_auto") :: Matter
	m.analysis.stage, m.thread = "model", {}
	s.selected = m.id
	action(s, "stop")
	local j = status.manual_judgment(); j.kind, j.manual = "deep", false
	update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j })
	t.eq(m.preparing, nil); t.eq(m.disposition, nil); t.eq(m.auto_task, nil)
end)

t.test("stopping or changing a commanded task while context is pending cancels automatic launch", function()
	local s = model()
	update.apply(s, { type = "bot-message", message = message("om_context_stop"), instruction = "排查" })
	local m = matter.find(s, "om_context_stop") :: Matter
	m.analysis.stage, m.thread = "model", {}
	local j = status.manual_judgment(); j.kind, j.manual = "deep", false
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j })
	local req = effects(out, "context")[1]
	s.selected = m.id
	action(s, "stop")
	out = context_ready(s, req)
	t.eq(#effects(out, "write-task"), 0); t.eq(m.preparing, nil); t.eq(m.auto_task, nil)
	t.eq(m.disposition, nil); t.eq(status.next_action(m).key, "task")
	-- A later command may start a new assessment, but a new message cancels its intent.
	update.apply(s, { type = "bot-message", message = message(m.id), instruction = "重新排查" })
	m.analysis.stage, m.thread = "model", {}
	out = update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j })
	req = effects(out, "context")[1]
	m.revision += 1
	update.apply(s, { type = "continue" })
	out = context_ready(s, req)
	t.eq(#effects(out, "write-task"), 0); t.eq(m.auto_task, nil); t.eq(m.preparing, nil)
end)

t.test("a changed default directory cancels a bot's pending automatic launch", function()
	local s = model(); s.cfg.settings.workspace = "/original"
	update.apply(s, { type = "bot-message", message = message("om_context_directory"), instruction = "排查" })
	local m = matter.find(s, "om_context_directory") :: Matter
	m.analysis.stage, m.thread = "model", {}
	local j = status.manual_judgment(); j.kind, j.manual = "deep", false
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = m.analysis.gen, judgment = j })
	local req = effects(out, "context")[1]
	s.cfg.settings.workspace = "/changed"
	out = context_ready(s, req)
	t.eq(#effects(out, "write-task"), 0); t.eq(m.auto_task, nil); t.eq(m.preparing, nil)
end)

t.test("a bot command targets the exact folded message and does not inherit an earlier analysis session", function()
	local s = model()
	local m = add(s, "om_first", "fyi")
	m.folded, m.latest_id, m.analysis.session, m.analysis.through = { "om_later" }, "om_later", "old-session", "om_later"
	m.thread = {}
	update.apply(s, { type = "bot-message", message = message("om_first", nil, "被指定的原消息"), instruction = "检查这一条" })
	t.eq(m.latest_id, "om_first"); t.eq(m.content, "被指定的原消息"); t.eq(m.analysis.session, nil); t.eq(m.thread, nil)
	local restored = snapshot.decode(snapshot.encode(s), s.cfg) :: Model
	t.eq(restored.items[1].instruction, "检查这一条")
end)

t.test("risk confirmation cannot be bypassed by a key action", function()
	local s = model(); local m = add(s, "risk", "deep")
	local judgment = m.analysis.judgment :: types.Judgment
	judgment.risk = "通过发布单"
	cache(m)
	t.eq(#effects(action(s, "primary"), "write-task"), 0)
	t.eq(m.preparing, nil); t.eq(m.disposition, nil)
	local out = action(s, "confirm-task")
	t.eq(#effects(out, "write-task"), 1)
	t.eq(#effects(out, "prepare"), 0); t.eq(#effects(out, "context"), 0)
	t.eq(m.disposition, "doing"); t.eq(status.next_action(m).key, "jump")
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

t.test("task edits discard context while typing and reassess only when editing ends", function()
	local s = model(); local m = add(s, "task", "deep"); m.thread = {}
	local pending = effects(update.apply(s, { type = "select", id = m.id }), "context")[1]
	t.eq(pending.task, "分析仓库")
	update.apply(s, { type = "focus", mode = "draft" })
	local typed = update.apply(s, { type = "field-key", key = { name = "paste", text = "，只读" } })
	t.eq(m.context, nil); t.eq(#effects(typed, "context"), 0)
	typed = update.apply(s, { type = "field-key", key = { name = "paste", text = "，不要修改" } })
	t.eq(#effects(typed, "context"), 0)
	t.eq(#effects(context_ready(s, pending, "old prompt"), "write-task"), 0)
	local out = update.apply(s, { type = "field-key", key = { name = "escape" } })
	local fresh = effects(out, "context"); t.eq(#fresh, 1)
	t.eq(fresh[1].task, status.task_text(m)); t.eq(fresh[1].revision, m.revision)
	context_ready(s, fresh[1], "edited prompt")
	out = action(s, "primary")
	t.eq(effects(out, "write-task")[1].prompt, "edited prompt")
	t.eq(#effects(out, "prepare"), 0); t.eq(#effects(out, "context"), 0)
end)

t.test("pending confirmation cannot launch and context callbacks must match generation revision and task", function()
	local s = model(); local m = add(s, "task", "deep"); m.thread = {}
	(m.analysis.judgment :: types.Judgment).risk = "发布"
	local req = effects(update.apply(s, { type = "select", id = m.id }), "context")[1]
	local out = action(s, "confirm-task")
	t.eq(#effects(out, "write-task"), 0); t.eq(#effects(out, "context"), 0); t.eq(#effects(out, "prepare"), 0)
	t.eq(status.next_action(m).key, "none")
	out = update.apply(s, { type = "context-prepared", id = m.id, gen = req.gen + 1, revision = req.revision, prompt = "stale" })
	t.eq((m.context :: types.TaskContext).phase, "model"); t.eq(#effects(out, "write-task"), 0)
	out = update.apply(s, { type = "context-prepared", id = m.id, gen = req.gen, revision = req.revision + 1, prompt = "stale" })
	t.eq((m.context :: types.TaskContext).phase, "model"); t.eq(#effects(out, "write-task"), 0)
	m.edits.task = "changed without a matching cached task"
	context_ready(s, req)
	t.eq(status.task_context(m), nil)
	m.edits.task = nil
	out = context_ready(s, req, "confirmed")
	t.eq(#effects(out, "write-task"), 0); t.eq(status.next_action(m).key, "task")
	out = action(s, "confirm-task")
	t.eq(effects(out, "write-task")[1].prompt, "confirmed"); t.eq(m.disposition, "doing")
end)

t.test("failed context remains failed until an explicit retry and retains its diagnostic needs", function()
	local s = model(); local m = add(s, "context-error", "deep"); m.thread = {}
	local req = effects(update.apply(s, { type = "select", id = m.id }), "context")[1]
	local needs = { plan = "unknown", materials = { choice = "unknown" }, discussion = { choice = "not_required" } }
	update.apply(s, { type = "context-prepared", id = m.id, gen = req.gen, revision = req.revision,
		error = "材料不足", needs = needs })
	local c = m.context :: types.TaskContext
	t.eq(c.phase, "failed"); t.eq(c.error, "材料不足"); t.eq(c.needs, needs)
	t.eq(status.next_action(m).key, "retry-context")
	t.eq(#effects(update.apply(s, { type = "tick" }), "context"), 0)
	t.eq(#effects(update.apply(s, { type = "select", id = m.id }), "context"), 0)
	local retried = effects(action(s, "retry-context"), "context"); t.eq(#retried, 1)
	t.eq(retried[1].gen ~= req.gen, true)
	t.eq(#effects(action(s, "retry-context"), "context"), 0)
	context_ready(s, req, "old success")
	t.eq((m.context :: types.TaskContext).phase, "model")
	context_ready(s, retried[1], "recovered")
	t.eq(status.next_action(m).key, "task")
end)

t.test("restored deep contexts are transient and assessed lazily for only the selected card", function()
	local s = model(); s.loaded = true
	local one = add(s, "restored-one", "deep"); local two = add(s, "restored-two", "deep")
	cache(one); cache(two)
	local restored = snapshot.decode(snapshot.encode(s), s.cfg) :: Model
	local first, second = restored.items[1], restored.items[2]
	t.eq(first.context, nil); t.eq(second.context, nil)
	first.thread, second.thread = {}, {}
	local out = update.apply(restored, { type = "init" })
	t.eq(#effects(out, "context"), 1); t.eq(effects(out, "context")[1].id, first.id)
	t.eq(second.context, nil)
	out = update.apply(restored, { type = "select", id = second.id })
	t.eq(#effects(out, "context"), 1); t.eq(effects(out, "context")[1].id, second.id)
end)

t.test("a fresh unselected deep result waits for thread prerequisites then assesses once", function()
	local s = model(); add(s, "selected-reply", "reply")
	local m = add(s, "fresh-deep", nil)
	m.analysis.phase, m.analysis.stage, m.analysis.gen = "running", "model", 10
	local j = status.manual_judgment(); j.kind, j.manual, j.task.prompt = "deep", false, "检查材料"
	local out = update.apply(s, { type = "analyzed", id = m.id, gen = 10, judgment = j })
	t.eq(#effects(out, "context"), 0); t.eq((m.context :: types.TaskContext).phase, "thread")
	local thread = effects(out, "thread")[1]
	out = update.apply(s, { type = "thread", id = m.id, gen = thread.gen, latest = m.id, messages = {} })
	local req = effects(out, "context")[1]
	t.eq(req.task, "检查材料"); t.eq(req.revision, m.revision)
	t.eq(#effects(update.apply(s, { type = "continue" }), "context"), 0)
	context_ready(s, req)
	t.eq(status.next_action(m).key, "task"); t.eq(m.disposition, nil)
end)

t.test("leaving a task editor by selecting another card assesses the edited task once", function()
	local s = model(); local m = add(s, "edited-card", "deep"); m.thread = {}
	local other = add(s, "other-card", "reply")
	update.apply(s, { type = "focus", mode = "draft" })
	update.apply(s, { type = "field-key", key = { name = "paste", text = "，只读" } })
	local out = update.apply(s, { type = "select", id = other.id })
	local req = effects(out, "context"); t.eq(#req, 1); t.eq(req[1].id, m.id)
	t.eq(s.mode, nil); t.eq(req[1].task, status.task_text(m))
	context_ready(s, req[1])
	out = update.apply(s, { type = "select", id = m.id })
	t.eq(#effects(out, "context"), 0); t.eq(status.next_action(m).key, "task")
end)

t.test("cached confirmation still refuses a hidden matter", function()
	local s = model(); local m = add(s, "hidden-ready", "deep")
	cache(m); m.hidden = true
	t.eq(#effects(action(s, "primary"), "write-task"), 0); t.eq(m.disposition, nil)
end)

t.test("manual task opens without starting analysis or requiring history", function()
	local s = model(); local m = add(s, "manual", nil)
	local out = action(s, "open-task")
	t.eq(#effects(out, "thread"), 0)
	t.eq(#effects(out, "analyze"), 0)
	t.eq(#effects(out, "context"), 0)
	local req = effects(out, "prepare")[1]; t.eq(req.task, nil)
	out = update.apply(s, { type = "prepared", id = m.id, gen = req.gen + 1, revision = req.revision, prompt = "stale" })
	t.eq(#effects(out, "write-task"), 0); t.eq(m.preparing, req.gen)
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

t.test("refresh reads mute settings only for chats still in question, never blocked or finished ones", function()
	local s = model(); s.cfg.settings.hide_muted = true; s.cfg.settings.hide_bots = true
	local open = add(s, "open", "reply"); open.chat_id = "c-open"
	local bot = add(s, "bot", "reply"); bot.chat_id = "c-bot"; bot.sender_type = "bot"
	local done = add(s, "done", "reply"); done.chat_id = "c-done"; done.disposition = "archived"
	local ruled = add(s, "ruled", "reply"); ruled.chat_id = "c-rule"
	s.cfg.rules["c-rule"] = { name = "Ruled", mode = "hide" }
	local fetch = effects(action(s, "refresh"), "fetch")[1]
	t.eq(fetch.items, nil)
	local out = update.apply(s, { type = "fetched", gen = fetch.gen, sources = {}, cursors = {} })
	local lookup = effects(out, "chat-settings")
	t.eq(#lookup, 1); t.eq(#lookup[1].ids, 1); t.eq(lookup[1].ids[1], "c-open")
	t.eq(#effects(out, "read-status"), 0)
	out = update.apply(s, { type = "chat-settings", gen = fetch.gen, ids = lookup[1].ids, fresh = {}, found = {},
		error = "部分群免打扰设置无法读取，已暂时隐藏这些群的消息。" })
	t.eq(#effects(out, "read-status"), 1)
	t.eq(open.hidden, true); t.eq(bot.hidden, true); t.eq(ruled.hidden, true); t.eq(done.hidden, false)
	assert(s.problem and string.find(s.problem, "免打扰", 1, true))
	-- Unblocking a chat asks only about chats whose answer is now needed and unknown.
	out = update.apply(s, { type = "setting", setting = "hide_bots", value = false })
	local after = effects(out, "chat-settings")
	t.eq(#after, 1); t.eq(after[1].gen, nil)
	local asked = {}; for _, id in after[1].ids do asked[id] = true end
	t.eq(asked["c-bot"], true); t.eq(asked["c-done"], nil); t.eq(asked["c-rule"], nil)
	update.apply(s, { type = "chat-settings", ids = after[1].ids, found = {
		["c-bot"] = { chat_id = "c-bot", is_muted = false, is_mute_at_all = false } } })
	t.eq(bot.hidden, false); t.eq(open.hidden, true)
end)

t.test("an event write failure shows once and clears on the next successful write", function()
	local s = model()
	local _, changed = update.apply(s, { type = "event-saved" })
	t.eq(changed, false)
	update.apply(s, { type = "event-failed", error = "disk full" })
	t.eq(s.event_warning, "工作台事件保存失败：disk full")
	update.apply(s, { type = "event-failed", error = "disk full" })
	local logged = 0
	for _, entry in s.log do if entry.text == s.event_warning then logged += 1 end end
	t.eq(logged, 1)
	_, changed = update.apply(s, { type = "event-saved" })
	t.eq(changed, true); t.eq(s.event_warning, nil)
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

t.test("workspace-only corrections invalidate context and stale callbacks cannot overwrite the new plan", function()
	local s = model(); local m = add(s, "workspace", "deep"); m.thread = {}
	s.command = "改在 /target 执行"
	local chat = effects(action(s, "run-command"), "converse")[1]
	local out = update.apply(s, { type = "conversed", id = m.id, gen = chat.gen, reply = "已改目录", change = { workspace = "/target" } })
	t.eq(status.task_workspace(m), "/target"); t.eq(status.task_text(m), "分析仓库")
	local correction = effects(out, "workbench-event")[1].event
	t.eq(correction.type, "workbench_chat"); t.eq(correction.data.user_said, "改在 /target 执行")
	t.eq(correction.data.content, nil)
	local req = effects(out, "context")[1]
	s.command = "改回默认目录"
	chat = effects(action(s, "run-command"), "converse")[1]
	out = update.apply(s, { type = "conversed", id = m.id, gen = chat.gen, reply = "已改", change = { workspace = "" } })
	local fresh = effects(out, "context")[1]
	t.eq(status.task_workspace(m), "")
	out = context_ready(s, req, "outdated")
	t.eq(#effects(out, "write-task"), 0); t.eq((m.context :: types.TaskContext).gen, fresh.gen)
	context_ready(s, fresh, "new workspace")
	out = action(s, "primary")
	t.eq(effects(out, "write-task")[1].workspace, "")
end)

t.test("an accepted task correction precomputes even after selecting a different card", function()
	local s = model(); local m = add(s, "changed-away", "deep"); m.thread = {}
	local other = add(s, "visible-reply", "reply")
	s.command = "只读检查"
	local req = effects(action(s, "run-command"), "converse")[1]
	update.apply(s, { type = "select", id = other.id })
	local out = update.apply(s, { type = "conversed", id = m.id, gen = req.gen,
		reply = "已修改", change = { task = "只读检查", risk = "" } })
	local fresh = effects(out, "context"); t.eq(#fresh, 1); t.eq(fresh[1].id, m.id)
	t.eq(fresh[1].task, "只读检查"); t.eq(fresh[1].revision, m.revision)
end)

t.test("structured directory survives task text editing and launch awaits durable confirmation", function()
	local s = model(); local m = add(s, "explicit", "deep"); m.thread = {}
	m.edits.workspace = "/target"
	m.edits.task = "执行 Workspace：/not-a-route\n只读排查"
	cache(m, "confirmed prompt")
	local out = action(s, "primary")
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
	local s = model(); local m = add(s, "directory-change", nil)
	s.cfg.settings.workspace = "/original"
	local req = effects(action(s, "open-task"), "prepare")[1]
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

t.test("phone message page opens on a tap and closes on back, Escape or a new filter", function()
	local s = model()
	add(s, "first", "reply"); add(s, "second", "reply")
	t.eq(s.reading, nil)
	update.apply(s, { type = "move", direction = 1 })
	t.eq(s.selected, "second"); t.eq(s.reading, nil)
	update.apply(s, { type = "select", id = "first" })
	t.eq(s.selected, "first"); t.eq(s.reading, true)
	t.eq(input.event(s, { ev = "action", act = "move", value = "1" }).type, "move")
	update.apply(s, input.event(s, { ev = "action", act = "move", value = "1" }))
	t.eq(s.selected, "second"); t.eq(s.reading, true)
	action(s, "back")
	t.eq(s.reading, nil)
	t.eq(input.key(s, { name = "escape" }), nil)
	update.apply(s, { type = "select", id = "first" })
	t.eq(input.key(s, { name = "escape" }).name, "back")
	action(s, "view", "later")
	t.eq(s.reading, nil)
	update.apply(s, { type = "select", id = "first" })
	action(s, "source", "dm")
	t.eq(s.reading, nil)
end)

t.done()

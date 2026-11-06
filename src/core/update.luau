--!strict
-- The only writer of the live workbench model. Updates own their model in place
-- (no copying the whole queue per keypress) and return data describing effects.
-- No Tern, filesystem, network, timers or settings reads here. All time comes
-- from cfg.now; every async result carries the request generation it belongs to.
local types = require("./types")
local matter = require("./matter")
local status = require("./status")
local views = require("./views")
local text = require("../shared/text")
local markup = require("../shared/markup")
local schema = require("../shared/schema")
local history = require("./history")

type Model = types.Model
type Matter = types.Matter
export type Effect = { type: string, [string]: any }
export type Event = { type: string, [string]: any }
local update = {}
local PUMP_ACTIONS = { view = true, source = true, force = true, retry = true, redraft = true, ["rule-del"] = true, ["rule-mode"] = true }

local function emit(out: { Effect }, effect: any)
	table.insert(out, effect)
end

local function next_gen(model: Model): number
	model.gen += 1
	return model.gen
end

local function selection(model: Model): views.Selection
	return { view = model.view, source = model.source, person = model.person }
end

local function current(model: Model): Matter?
	return matter.find(model, model.selected)
end

local function queue(model: Model): { Matter }
	return views.visible(model.items, selection(model))
end

local function index_of(list: { Matter }, id: string?): number
	for i, m in list do
		if m.id == id then return i end
	end
	return 1
end

local function reselect(model: Model, near: number?)
	local shown = queue(model)
	for _, m in shown do
		if m.id == model.selected then return end
	end
	local m = shown[math.clamp(near or 1, 1, math.max(1, #shown))]
	model.selected = if m then m.id else nil
	model.draft_cursor = if m then text.len(status.field_text(m)) else 0
end

local function focus(model: Model, mode: string?, out: { Effect })
	model.mode = mode
	emit(out, { type = "focus", mode = mode, setting = model.settings_cursor })
end

local function record(m: Matter, out: { Effect })
	emit(out, { type = "record", ids = status.ids(m), outcome = m.disposition })
end

local function resolve(model: Model, m: Matter, disposition: types.Disposition?, verb: string, out: { Effect })
	local at = index_of(queue(model), m.id)
	model.undo = { kind = "triage", id = m.id, previous = m.disposition }
	m.disposition, m.reopened = disposition, nil
	m.revision += 1
	if m.task then m.task.new_messages = 0 end
	record(m, out)
	model.flash = verb .. "：" .. m.name
	matter.log(model, "你", verb .. "：" .. m.name .. "（" .. m.chat .. "）")
	reselect(model, at)
end

local function open_message(model: Model, m: Matter, out: { Effect })
	if text.is_chat_link(m.link) then
		emit(out, { type = "open", url = m.link })
	else
		emit(out, { type = "toast", title = "该消息没有可用的原消息链接", detail = m.id })
	end
end

local function copy_and_go(model: Model, m: Matter, out: { Effect })
	local reply = status.reply_text(m)
	if string.find(reply, "%S") then emit(out, { type = "copy", text = reply }) end
	open_message(model, m, out)
end

local function request_thread(model: Model, m: Matter, out: { Effect })
	if m.thread or m.loading_thread then return end
	m.loading_thread, m.thread_gen = true, next_gen(model)
	emit(out, { type = "thread", id = m.id, gen = m.thread_gen, latest = m.latest_id or m.id,
		chat_id = m.chat_id, count = model.cfg.settings.thread_size,
		until_time = if m.chat_type == "p2p" then nil else m.time })
end

local function request_image(model: Model, id: string, key: string, out: { Effect })
	local cached = model.images[key]
	if cached and (cached.pending or cached.failed or cached.blob) then return end
	if cached then cached.pending = true else model.images[key] = { pending = true } end
	emit(out, { type = "image", message_id = id, key = key })
end

local function show_images(model: Model, m: Matter, out: { Effect })
	if not model.cfg.settings.show_images then return end
	for _, message in m.thread or {} do
		if not message.deleted then
			for _, key in markup.images(message.content, 4) do request_image(model, message.id, key, out) end
		end
	end
end

local function select_item(model: Model, id: string, out: { Effect })
	if model.selected ~= id then
		model.command, model.command_cursor, model.flash = "", 0, nil
	end
	model.selected = id
	local m = current(model)
	model.draft_cursor = if m then text.len(status.field_text(m)) else 0
	if model.mode == "draft" then focus(model, nil, out) end
	if m then request_thread(model, m, out); show_images(model, m, out) end
end

-- The same source key is used by fetching and has_more; a cursor belongs to its lookback.
function update.has_more(model: Model): boolean
	local suffix = "|" .. tostring(model.cfg.settings.lookback_days)
	for key, cursor in model.cursors do
		if cursor.token and string.sub(key, -#suffix) == suffix then return true end
	end
	return false
end

local function refresh(model: Model, more: boolean, out: { Effect })
	if model.loading or (more and (not model.me or not update.has_more(model))) then return end
	model.loading, model.loading_more, model.problem = true, more, nil
	model.fetch_gen = next_gen(model)
	if not more then model.last_refresh = model.cfg.now end
	emit(out, { type = "fetch", gen = model.fetch_gen, more = more, settings = model.cfg.settings,
		stars = model.cfg.stars, cursors = model.cursors, items = model.items, me = model.me })
end

local function extras(model: Model, except: Matter): any
	local others = {}
	for _, m in model.items do
		if m ~= except and status.pending(m) and not m.no_agent and #others < 12 then
			local j = m.analysis.judgment
			table.insert(others, { sender = m.name, chat = m.chat,
				summary = if j then j.summary else text.clip(markup.clean(m.content), 200) })
		end
	end
	return { others = others, agenda = if model.cfg.settings.use_agenda then model.agenda else nil }
end

local function task_title(m: Matter, task: string?): string
	local j = m.analysis.judgment
	local what = if task and j and j.task.title ~= "" then j.task.title
		elseif j and j.summary ~= "" then j.summary else markup.clean(m.content)
	local who = if m.chat_type == "p2p" then m.name else m.name .. "@" .. m.chat
	return "飞书: " .. text.clip(text.flat(what), 24) .. " · " .. text.clip(text.flat(who), 16)
end

local function start_task(model: Model, m: Matter, task: string?, out: { Effect })
	if m.preparing then return end
	m.preparing = next_gen(model)
	m.preparation = { gen = m.preparing, revision = m.revision, task = task, stage = "thread" }
	model.flash = if task then "正在判断任务与飞书消息的关联性…" else "正在打开任务页…"
	if task then request_thread(model, m, out) end
end

local function start_edit(model: Model, m: Matter, out: { Effect })
	if not status.can_edit(m) then return end
	local a = m.analysis
	if not a.judgment then a.phase, a.judgment = "done", status.manual_judgment() end
	if a.judgment and a.judgment.kind == "fyi" then a.judgment.kind = "reply" end
	model.draft_cursor = text.len(status.field_text(m))
	focus(model, "draft", out)
end

local function start_chat(model: Model, out: { Effect })
	local m = current(model)
	if not m or model.talking or not string.find(model.command, "%S") or not status.can_adjust(m) then return end
	if m.no_agent then model.flash = "这条不交给 AI。按 g 让 AI 分析后再聊"; return end
	local said = model.command
	model.command, model.command_cursor, model.talking = "", 0, m.id
	model.chat_request = { id = m.id, gen = next_gen(model), revision = m.revision, said = said, stage = "thread" }
	table.insert(m.talk, { me = true, text = said })
	model.flash = "AI 正在回答…"
	matter.log(model, "你", "对 AI 说：" .. said)
	emit(out, { type = "save-now" })
	request_thread(model, m, out)
end

local function primary(model: Model, m: Matter, confirmed: boolean, out: { Effect })
	if status.needs_confirm(m) and not confirmed then
		local j = m.analysis.judgment
		model.flash = "这条涉及" .. (if j then j.risk else "高风险动作") .. "，请点击按钮确认后再执行"
		return
	end
	local action = status.next_action(m).key
	if action == "archive" then
		resolve(model, m, "archived", "已归档", out)
	elseif action == "copy" then
		copy_and_go(model, m, out)
		if m.disposition ~= "handoff" then
			m.handoff_at = model.cfg.now
			resolve(model, m, "handoff", "已复制，去飞书发送", out)
		end
	elseif action == "task" then
		start_task(model, m, status.task_text(m), out)
	elseif action == "jump" then
		if m.task then m.task.new_messages = 0 end
		emit(out, { type = "open-task", id = m.id })
	elseif action == "reopen" then
		if m.task then m.task.phase = "starting" end
		emit(out, { type = "reopen-task", id = m.id })
	end
end

local function change_rule(model: Model, chat_id: string, rule: any, out: { Effect })
	model.cfg.rules[chat_id] = rule
	emit(out, { type = "rule", chat_id = chat_id, rule = rule })
	matter.apply_rules(model)
	reselect(model, 1)
end

local function setting_changed(model: Model, id: string, value: any, out: { Effect })
	model.cfg.settings[id] = schema.coerce(id, value)
	model.settings_cursor = id
	emit(out, { type = "setting", id = id, value = model.cfg.settings[id] })
	matter.apply_rules(model)
	reselect(model, 1)
end

local function undo(model: Model, out: { Effect })
	local last = model.undo
	if not last then return end
	model.undo = nil
	if last.kind == "rule" then
		change_rule(model, last.chat_id, last.previous, out)
		model.flash, model.selected = "已撤销会话规则", last.id
		reselect(model, 1)
	else
		local m = matter.find(model, last.id)
		if not m then return end
		m.disposition, m.spoken = last.previous, nil
		m.revision += 1
		if last.previous == "handoff" then m.handoff_at = model.cfg.now end
		record(m, out)
		model.flash = "已撤销：" .. m.name
		matter.log(model, "你", "撤销了对 " .. m.name .. " 的操作")
		model.view, model.person, model.selected = "pending", nil, m.id
		model.draft_cursor = text.len(status.field_text(m))
	end
end

local function action(model: Model, event: Event, out: { Effect })
	local name, value = event.name, event.value
	local m = current(model)
	if name == "view" then
		if not views.known(value) then return end
		model.page = nil
		if model.mode then focus(model, nil, out) end
		model.view, model.person, model.selected = value, nil, nil
		model.command, model.command_cursor, model.flash = "", 0, nil
		reselect(model, 1)
	elseif name == "source" then
		if value ~= "all" and value ~= "mention" and value ~= "dm" then return end
		model.source, model.person, model.selected = value, nil, nil
		reselect(model, 1)
	elseif name == "person" then
		model.person = if model.person == value then nil else value
		model.selected = nil; reselect(model, 1)
	elseif name == "refresh" then refresh(model, false, out)
	elseif name == "load-more" then refresh(model, true, out)
	elseif name == "settings" then
		focus(model, nil, out)
		model.page = if model.page == "settings" then nil else "settings"
		if not model.page then refresh(model, false, out) end
	elseif name == "undo" then undo(model, out)
	elseif name == "run-command" then start_chat(model, out)
	elseif name == "set" then
		local id, at = string.match(value or "", "^([%w_]+):(%d+)$")
		if id and schema.known(id) then
			local choices = schema.field(id).choices
			if choices and choices[tonumber(at) :: number] ~= nil then
				setting_changed(model, id, choices[tonumber(at) :: number], out)
			end
		end
	elseif name == "rule-del" and value then change_rule(model, value, nil, out)
	elseif name == "rule-mode" and value then
		local r = model.cfg.rules[value]
		if r then change_rule(model, value, { name = r.name, mode = if r.mode == "hide" then "manual" else "hide" }, out) end
	elseif name == "close-thread" then model.dialog = nil
	elseif not m then return
	elseif name == "open-thread" then focus(model, nil, out); model.dialog = m.id
	elseif name == "primary" or name == "confirm-task" then
		if name ~= "confirm-task" or status.needs_confirm(m) then primary(model, m, name == "confirm-task", out) end
	elseif name == "copy" then
		if status.stale(m) then model.flash = "有新消息，等新的判断出来再复制" else copy_and_go(model, m, out) end
	elseif name == "confirm-reply" and m.disposition == "handoff" and m.spoken then
		resolve(model, m, "replied", "已确认回复", out)
	elseif name == "archive" then
		if not status.settled(m) then resolve(model, m, "archived", "已归档", out) end
	elseif name == "open-task" then
		if m.disposition == "doing" then
			if m.task then m.task.new_messages = 0 end
			emit(out, { type = "open-task", id = m.id })
		else start_task(model, m, nil, out) end
	elseif name == "force" then
		local a = m.analysis
		if status.settled(m) or a.phase == "running" or (a.judgment and not a.judgment.manual) then return end
		a.judgment, a.force, a.phase, a.backlog, a.settle_at = nil, true, "queued", false, nil
		m.no_agent = false
	elseif name == "snooze" then
		if m.disposition == "snoozed" then
			model.undo, m.disposition = nil, nil
			m.revision += 1; record(m, out)
			model.flash = "已移回待处理：" .. m.name; reselect(model, nil)
		elseif not status.settled(m) then resolve(model, m, "snoozed", "稍后处理", out) end
	elseif name == "redraft" or name == "retry" then
		if name == "retry" or status.of(m) == "failed" then m.analysis.phase, m.analysis.settle_at = "queued", nil end
	elseif name == "edit" then start_edit(model, m, out)
	elseif name == "open" then open_message(model, m, out)
	elseif name == "star" then
		local found = false
		local list = {}
		for _, star in model.cfg.stars do
			if star.id == m.sender_id then found = true else table.insert(list, star) end
		end
		if not found then table.insert(list, { id = m.sender_id, name = m.name }) end
		model.cfg.stars = list
		emit(out, { type = "stars", list = list })
		model.flash = (if found then "已取消星标：" else "已星标：") .. m.name
		matter.apply_rules(model)
		if not found then refresh(model, false, out) end
	elseif name == "hide-chat" or name == "manual-chat" then
		local mode = if name == "hide-chat" then "hide" else "manual"
		local before = model.cfg.rules[m.chat_id]
		local rule = if before and before.mode == mode then nil else { mode = mode, name = m.chat }
		model.undo = { kind = "rule", id = m.id, chat_id = m.chat_id, previous = before }
		change_rule(model, m.chat_id, rule, out)
		model.flash = if not rule then "已移除规则：" .. m.chat
			elseif mode == "hide" then "不再显示：" .. m.chat else "不再交给 AI 分析：" .. m.chat
		matter.log(model, "你", model.flash :: string)
	end
end

-- A focused field owns character keys; shortcuts never run while it is editing.
local function edit_key(model: Model, key: any, out: { Effect }): boolean
	if key.name == "escape" then focus(model, nil, out); return true end
	local mode = model.mode
	if mode == "setting" then
		if key.name == "enter" then focus(model, nil, out); return true end
		local field = { text = model.cfg.settings[model.settings_cursor], cursor = model.field_cursor }
		local changed = text.key(field, key)
		setting_changed(model, model.settings_cursor, field.text, out)
		model.field_cursor = field.cursor
		return changed
	elseif mode == "command" then
		local m = current(model)
		if m and not status.can_adjust(m) then focus(model, nil, out); return true end
		if key.name == "enter" then focus(model, nil, out); start_chat(model, out); return true end
		local field = { text = model.command, cursor = model.command_cursor }
		local changed = text.key(field, key)
		model.command, model.command_cursor = field.text, field.cursor
		return changed
	end
	local m = current(model)
	if not m or not status.editable(m) then focus(model, nil, out); return true end
	local field = { text = status.field_text(m), cursor = model.draft_cursor }
	local changed = text.key(field, if key.name == "enter" then { name = "paste", text = "\n" } else key)
	if field.text ~= status.field_text(m) then
		if status.kind(m) == "deep" then m.edits.task = field.text else m.edits.reply = field.text end
		m.revision += 1
	end
	model.draft_cursor = field.cursor
	return changed
end

local function advance(model: Model, out: { Effect })
	-- Finish pending thread/image prerequisites. No nested callback mutates a matter.
	for _, m in model.items do
		local a = m.analysis
		if a.phase == "running" and a.stage ~= "model" then
			if a.reanalyze then
				a.phase, a.stage, a.reanalyze = "queued", nil, false
			elseif m.disposition == "replied" then
				a.phase, a.stage = "done", nil
			elseif m.thread then
				local keys = if model.cfg.settings.agent_images then markup.images(m.content, 3) else {}
				local paths, waiting = {}, false
				for _, key in keys do
					request_image(model, m.latest_id or m.id, key, out)
					local image = model.images[key]
					if image.pending then waiting = true elseif image.path then table.insert(paths, image.path) end
				end
				if not waiting then
					a.stage, a.resumed = "model", a.session ~= nil
					emit(out, { type = "analyze", id = m.id, gen = a.gen, matter = m, extras = extras(model, m), images = paths })
				end
			else request_thread(model, m, out) end
		end
		local p = m.preparation
		if p and p.stage == "thread" and (not p.task or m.thread) then
			p.stage = "model"
			emit(out, { type = "prepare", id = m.id, gen = p.gen, revision = p.revision, task = p.task, matter = m })
		elseif p and p.stage == "thread" then request_thread(model, m, out) end
	end
	local chat = model.chat_request
	if chat and chat.stage == "thread" then
		local m = matter.find(model, chat.id)
		if not m then model.chat_request, model.talking = nil, nil
		elseif m.thread then
			chat.stage = "model"
			emit(out, { type = "converse", id = m.id, gen = chat.gen, revision = chat.revision, matter = m,
				extras = extras(model, m), said = chat.said, current = {
					decision = status.kind(m) or "未判断", draft = status.reply_text(m), task = status.task_text(m),
				} })
		else request_thread(model, m, out) end
	end
	-- Running work is counted from the model, never by increment/decrement callbacks.
	local active = 0
	for _, m in model.items do if m.analysis.phase == "running" then active += 1 end end
	while model.queue_enabled and active < model.cfg.settings.concurrency do
		local chosen = current(model)
		local function ready(m: Matter): boolean
			local a = m.analysis
			return a.phase == "queued" and not m.no_agent and not m.hidden and not m.preparing
				and (not a.settle_at or a.settle_at <= model.cfg.now)
		end
		if not (chosen and ready(chosen) and (not chosen.disposition or chosen.disposition == "snoozed")) then
			chosen = nil
			for _, m in views.visible(model.items, { view = "pending", source = "all" }) do
				if ready(m) and not m.disposition and not m.analysis.backlog then chosen = m; break end
			end
		end
		if not chosen then break end
		local a = chosen.analysis
		a.phase, a.error, a.gen, a.stage = "running", nil, next_gen(model), "thread"
		active += 1
		matter.log(model, "agent", chosen.name .. "：开始分析")
		emit(out, { type = "save-now" })
		request_thread(model, chosen, out)
		-- A cached thread doesn't produce a callback: the next dispatch advances it.
		emit(out, { type = "continue" })
	end
	local soonest: number? = nil
	for _, m in model.items do
		local a = m.analysis
		if a.phase == "queued" and a.settle_at and a.settle_at > model.cfg.now then soonest = math.min(soonest or a.settle_at, a.settle_at) end
	end
	if soonest ~= model.wake_at then
		model.wake_at = soonest
		emit(out, { type = "wake", at = soonest })
	end
end

-- Apply an event to the owned model and return effects. `false` means a key did
-- nothing and Tern need not render/save. Every async path validates its generation.
function update.apply(model: Model, event: Event): ({ Effect }, boolean)
	local out: { Effect } = {}
	local m = if type(event.id) == "string" then matter.find(model, event.id) else nil
	local ty = event.type
	if ty == "history" or (ty == "action" and event.name == "history") then
		local h = model.history or history.empty()
		model.history = h
		if ty == "action" then
			model.page = "history"
			focus(model, nil, out)
			event = { type = "history", name = "open" }
		end
		for _, effect in history.apply(h, event) do emit(out, effect) end
		emit(out, { type = "save" })
		return out, true
	end
	if ty == "select" or ty == "move" or ty == "read-status" or ty == "setting" then
		model.queue_enabled = true
	elseif ty == "action" and PUMP_ACTIONS[event.name] then
		model.queue_enabled = true
	elseif ty == "init" and not model.loaded then model.queue_enabled = true end
	if ty == "init" then
		matter.apply_rules(model); reselect(model, nil)
		if model.loaded then
			emit(out, { type = "poll-tasks" })
			local selected = current(model)
			if selected then show_images(model, selected, out) end
		else refresh(model, false, out) end
		if model.page == "history" then
			local h = model.history or history.empty()
			model.history = h
			for _, effect in history.apply(h, { name = "open" }) do emit(out, effect) end
		end
	elseif ty == "action" then action(model, event, out)
	elseif ty == "select" then
		if m then select_item(model, m.id, out); if event.open then open_message(model, m, out) end end
	elseif ty == "move" then
		local shown = queue(model)
		if #shown > 0 then select_item(model, shown[math.clamp(index_of(shown, model.selected) + event.direction, 1, #shown)].id, out) end
	elseif ty == "focus" then
		if event.mode == "setting" and schema.known(event.setting) then
			model.settings_cursor = event.setting
			model.field_cursor = text.len(model.cfg.settings[event.setting])
			focus(model, "setting", out)
		elseif event.mode == "command" then
			local selected = current(model)
			if selected and status.can_adjust(selected) then focus(model, "command", out) end
		elseif event.mode == "draft" then local selected = current(model); if selected then start_edit(model, selected, out) end end
	elseif ty == "field-key" then
		if not edit_key(model, event.key, out) then return out, false end
	elseif ty == "setting" then setting_changed(model, event.setting, event.value, out)
	elseif ty == "settings-move" then
		local order = schema.order()
		local at = table.find(order, model.settings_cursor) or 1
		model.settings_cursor = order[math.clamp(at + event.direction, 1, #order)]
	elseif ty == "settings-activate" then
		local field = schema.field(model.settings_cursor)
		if field.kind == "text" and not event.direction then
			model.field_cursor = text.len(model.cfg.settings[field.id]); focus(model, "setting", out)
		else setting_changed(model, field.id, schema.step(field.id, model.cfg.settings[field.id], event.direction or 1), out) end
	elseif ty == "settings-close" then model.page = nil; refresh(model, false, out)
	elseif ty == "tick" then
		local minutes = model.cfg.settings.poll_minutes
		if minutes > 0 and model.cfg.now - (model.last_refresh or model.cfg.now) >= minutes * 60 then refresh(model, false, out) end
	elseif ty == "notice" then
		if model.runtime_warning ~= event.warning then
			model.runtime_warning = event.warning
			if event.warning then matter.log(model, "AI", event.warning) end
		end
	elseif ty == "fetched" then
		if event.gen ~= model.fetch_gen then return out, false end
		if event.error and not event.sources then
			model.loading, model.loading_more, model.problem = false, false, event.error
		else
			local before = {}; for _, old in model.items do before[old.id] = true end
			model.me, model.problem = event.me or model.me, event.error
			if event.agenda ~= nil or not model.cfg.settings.use_agenda then model.agenda = event.agenda end
			model.cursors = event.cursors or model.cursors
			if event.chat_settings then model.chat_settings = event.chat_settings end
			matter.merge(model, event.sources or {}, event.decisions or {}, out)
			local added = 0
			if model.loading_more then
				for _, it in model.items do
					if not before[it.id] then it.analysis.backlog = true; if not it.disposition and not it.hidden then added += 1 end end
				end
			end
			local ids = {}
			for _, it in model.items do
				if not it.hidden and not status.settled(it) then for _, id in status.ids(it) do table.insert(ids, id) end end
			end
			emit(out, { type = "read-status", gen = event.gen, ids = ids, added = added })
		end
	elseif ty == "read-status" then
		if event.gen ~= model.fetch_gen then return out, false end
		if event.error then model.problem = (if model.problem then model.problem .. "\n" else "") .. "已读状态：" .. event.error end
		for _, it in model.items do
			if not it.hidden and not status.settled(it) then
				local read: boolean? = true
				for _, id in status.ids(it) do
					if event.found[id] == false then read = false; break elseif event.found[id] == nil then read = nil end
				end
				it.is_read = read
			end
		end
		if not model.backlog_marked then
			model.backlog_marked = true
			for at, it in views.visible(model.items, { view = "pending", source = "all" }) do it.analysis.backlog = at > model.cfg.settings.backlog end
		end
		if model.loading_more and not model.problem then
			model.flash = if event.added > 0 then "又加载了 " .. tostring(event.added) .. " 条待处理消息，选中后才会分析"
				elseif update.has_more(model) then "这一页没有新的待处理消息，可以继续加载" else "这段时间内的消息都已加载"
		end
		model.loading, model.loading_more, model.loaded = false, false, model.loaded or model.problem == nil or #model.items > 0
		for _, it in model.items do
			if status.settled(it) and not (model.undo and model.undo.id == it.id) then
				if it.analysis.session then emit(out, { type = "forget", session = it.analysis.session }); it.analysis.session = nil end
				emit(out, { type = "delete-task", id = it.id })
			elseif it.disposition == "handoff" and model.me then emit(out, { type = "spoken", id = it.id, revision = it.revision, chat_id = it.chat_id, me = model.me, since = it.handoff_at or model.cfg.now }) end
		end
		emit(out, { type = "poll-tasks" })
		reselect(model, nil)
		local selected = current(model); if selected then request_thread(model, selected, out) end
	elseif ty == "thread" and m then
		if not m.loading_thread or m.thread_gen ~= event.gen then return out, false end
		m.loading_thread, m.thread_gen = nil, nil
		if event.latest ~= (m.latest_id or m.id) then request_thread(model, m, out)
		else
			local thread, seen = {}, false
			for _, message in event.messages or {} do
				if type(message) == "table" and type(message.message_id) == "string" then
					local from = message.sender
					local mine = type(from) == "table" and from.id == model.me
					table.insert(thread, { id = message.message_id, sender = if mine then "我" elseif type(from) == "table" then tostring(from.name or from.id or "?") else "?",
						time = tostring(message.create_time or ""), content = tostring(message.content or ""), deleted = message.deleted == true, mine = mine })
					seen = seen or message.message_id == (m.latest_id or m.id)
				end
			end
			if not seen then table.insert(thread, { id = m.latest_id or m.id, sender = m.name, time = m.time, content = m.content, deleted = m.deleted, mine = false }) end
			m.thread, m.thread_error = thread, event.error
			local last = thread[#thread]
			if event.messages and m.chat_type == "p2p" and last and last.mine and not m.disposition then
				m.disposition = "replied"; m.revision += 1; record(m, out)
				matter.log(model, "AI", m.name .. "：你已在飞书回复，移到已处理")
			end
			show_images(model, m, out); reselect(model, nil)
		end
	elseif ty == "image" then
		model.images[event.key] = { path = event.path, failed = event.path == nil, blob = event.blob }
	elseif ty == "analyzed" and m then
		local a = m.analysis
		if a.phase ~= "running" or a.gen ~= event.gen then return out, false end
		a.session, a.run = event.session or a.session, event.run or a.run
		if a.reanalyze then
			a.phase, a.stage, a.reanalyze, m.thread = "queued", nil, false, nil
		elseif event.error then
			a.phase, a.error, a.stage = "failed", event.error, nil
			if a.resumed then a.session = nil end
			matter.log(model, "AI", m.name .. "：分析失败")
		else
			a.phase, a.error, a.stage, a.judgment, a.through = "done", nil, nil, event.judgment, event.through
			m.edits = {}
			if model.selected == m.id then model.draft_cursor = text.len(status.field_text(m)) end
			matter.log(model, "AI", m.name .. "：标记为 " .. event.judgment.pri .. "，" .. status.LABELS[event.judgment.kind][1])
		end
	elseif ty == "conversed" then
		local req = model.chat_request
		if not req or req.gen ~= event.gen or not m then return out, false end
		model.chat_request, model.talking = nil, nil
		m.analysis.session = event.session or m.analysis.session
		if event.error then table.insert(m.talk, { text = "（失败）" .. event.error }); model.flash = "AI 回答失败"
		else
			table.insert(m.talk, { text = event.reply or "" })
			model.flash = "AI 已回答"
			local change = event.change or {}
			if req.revision ~= m.revision then model.flash = "消息或任务已变化，本轮回答未覆盖当前内容"
			elseif change.kind or change.draft or change.task then
				local a = m.analysis
				if not a.judgment then a.phase, a.judgment = "done", status.manual_judgment() end
				local j = a.judgment :: types.Judgment
				j.kind = change.kind or j.kind
				if change.draft then j.draft, m.edits.reply = change.draft, nil end
				if change.task then j.task.prompt, m.edits.task, j.risk = change.task, nil, change.risk or "" end
				m.revision += 1
				if model.selected == m.id then model.draft_cursor = text.len(status.field_text(m)) end
				model.flash = "AI 已更新判断"; reselect(model, nil)
			end
		end
	elseif ty == "prepared" and m then
		local p = m.preparation
		if not p or p.gen ~= event.gen then return out, false end
		m.preparing, m.preparation = nil, nil
		if p.revision ~= m.revision or m.hidden or (p.task and status.stale(m)) then model.flash = "任务或消息已变化，请重新确认后再执行"
		elseif event.error then model.flash = "执行前分析失败，请重试"; emit(out, { type = "toast", title = model.flash, detail = event.error })
		else
			m.task = { phase = "starting", new_messages = 0 }
			emit(out, { type = "write-task", id = m.id, prompt = event.prompt, title = task_title(m, p.task) })
			resolve(model, m, "doing", "已开始任务", out)
			emit(out, { type = "save-now" })
			emit(out, { type = "open-task", id = m.id })
		end
	elseif ty == "task-missing" and m then start_task(model, m, if m.analysis.judgment then status.task_text(m) else nil, out)
	elseif ty == "tasks" then
		for _, it in model.items do
			if it.disposition ~= "doing" then continue end
			local task = event.tasks[it.id]
			local phase = if task then task.state else "closed"
			local raw = if task and type(task.result) == "string" then task.result else nil
			if not it.task then it.task = { phase = "closed", new_messages = 0 } end
			local t = it.task :: types.Task
			if phase == t.phase and raw == t.raw then continue end
			t.phase, t.raw, t.result = phase, raw, raw
			if phase == "done" then
				local reply = raw and string.match(raw, "<reply>%s*(.-)%s*</reply>")
				t.result = raw and string.gsub(raw, "%s*<reply>.-</reply>%s*", "\n")
				if reply and reply ~= "" then
					local a = it.analysis
					if not a.judgment then a.phase, a.judgment = "done", status.manual_judgment() end
					local j = a.judgment :: types.Judgment
					j.kind, j.draft, it.edits.reply, it.disposition = "reply", reply, nil, nil
					it.revision += 1; record(it, out)
				end
				model.flash = "任务本轮结束，请核对结果：" .. it.name
				matter.log(model, "任务", model.flash :: string)
			end
		end
		reselect(model, nil)
	elseif ty == "spoken" and m then
		if m.disposition == "handoff" and m.revision == event.revision and type(event.text) == "string" and event.text ~= m.spoken then
			m.spoken, model.flash = event.text, "检测到可能的回复，请确认：" .. event.text
		end
	elseif ty == "continue" or ty == "wake" then
		-- The effect runner woke a queue waiting on cached data or a settle deadline.
	else return out, false end
	advance(model, out)
	emit(out, { type = "save" })
	return out, true
end

-- Render data, computed from one model snapshot. No storage reads in the UI.
function update.facts(model: Model): any
	local counts = views.counts(model.items)
	local defs, running = {}, 0
	for _, v in views.LIST do table.insert(defs, { id = v.id, label = v.label, count = counts[v.id] }) end
	for _, m in model.items do if m.analysis.phase == "running" then running += 1 end end
	local m = current(model)
	return { running = running, views = defs, queue = queue(model), has_more = update.has_more(model),
		item = m, dialog_item = matter.find(model, model.dialog),
		draft = if m then status.field_text(m) else "", reply_draft = if m then status.reply_text(m) else "" }
end

return update

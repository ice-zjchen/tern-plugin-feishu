-- The host runtime owns IO and lifecycle, not domain transitions. Every result
-- enters core/update as an event. It starts with the plugin and keeps polling,
-- analyzing and syncing tasks with no workbench open; panes only display it.
local tern = require("tern")
local update = require("../core/update")
local views = require("../core/views")
local snapshot = require("../core/snapshot")
local ai = require("../services/ai")
local omp = require("../services/omp")
local lark = require("../services/lark")
local store = require("../services/store")
local settings = require("../shared/settings")
local bridge = require("../shared/bridge")
local markup = require("../shared/markup")
local ids = require("../ui/ids")
local input = require("../ui/input")
local ui = require("../ui/inbox")
local fetch = require("./fetch")
local workbench_events = require("../services/events")
local launch = require("../services/launch")
local status = require("../core/status")
local task_rules = require("../core/task")
local bot = require("./bot")

local runtime = {}
local active = nil
local MAX_IMAGE_BYTES = 20 * 1024 * 1024

local function config()
	local owner = tern.kv.get("bot_owner")
	local profile = settings.get("bot_profile")
	return { settings = settings.all(), rules = settings.rules(), stars = store.stars(), now = os.time(), home = tern.getenv("HOME"),
		bot_owner = if type(owner) == "table" and profile ~= "" and owner.profile == profile then owner.open_id else nil }
end

local function mime(bytes: string): string
	if string.sub(bytes, 1, 4) == "\137PNG" then return "image/png"
	elseif string.sub(bytes, 1, 3) == "GIF" then return "image/gif"
	elseif string.sub(bytes, 1, 4) == "RIFF" and string.sub(bytes, 9, 12) == "WEBP" then return "image/webp" end
	return "image/jpeg"
end

local function context(rt)
	local existing = {}
	for _, pane in tern.pane.list() do existing[pane.pane] = true end
	local found = nil
	for id, cx in rt.panes do
		if existing[id] then found = found or cx else rt.panes[id] = nil end
	end
	return found
end

local function cancel(rt, name)
	local timer = rt.timers[name]
	if timer then timer:cancel(); rt.timers[name] = nil end
end

local function alive(rt): boolean
	return active == rt
end

local function timer(rt, name, ms, fn)
	cancel(rt, name)
	rt.timers[name] = tern.timer(ms, function()
		rt.timers[name] = nil
		if alive(rt) then fn() end
	end)
end

local dispatch, execute, poll_tasks

local function sync_timers(rt)
	if not rt.timers.tick then
		timer(rt, "tick", 60000, function() dispatch(rt, { type = "tick" }) end)
	end
	local tasked = false
	for _, m in rt.model.items do
		if not status.settled(m) and (m.disposition == "doing" or (m.task and m.task.request_id)) then tasked = true; break end
	end
	if tasked and not rt.timers.tasks then
		timer(rt, "tasks", 3000, function() poll_tasks(rt); if alive(rt) then sync_timers(rt) end end)
	elseif not tasked then cancel(rt, "tasks") end
	-- The profile is applied once you leave its field, not on every keystroke.
	local editing = rt.model.mode == "setting" and rt.model.settings_cursor == "bot_profile"
	local profile = if editing and rt.bot then rt.bot.profile elseif editing then "" else settings.get("bot_profile")
	local before = rt.bot
	-- Reports may arrive inside this call; deferring them keeps dispatch from re-entering here.
	rt.bot = bot.sync(rt.bot, profile, function(err)
		tern.timer(1, function() if alive(rt) then dispatch(rt, { type = "bot-status", error = err }) end end)
	end)
	if rt.bot ~= before then
		-- A new or first bot needs binding unless this profile already knows you.
		rt.model.bot_code = nil
		if rt.bot and not config().bot_owner then
			local listener = rt.bot
			tern.process.run({ "/usr/bin/uuidgen" }, function(result)
				if rt.bot ~= listener or settings.get("bot_profile") ~= profile then return end
				local code = (string.gsub(string.lower(result.stdout or ""), "[%s%-]", ""))
				if result.status == 0 and #code == 32 and string.match(code, "^%x+$") then
					dispatch(rt, { type = "bot-code", code = code })
				else
					dispatch(rt, { type = "bot-status", error = "无法生成机器人绑定码，未开放绑定。" })
				end
			end)
		end
	end
	if rt.bot and not rt.timers.bot then
		timer(rt, "bot", 2000, function()
			bot.drain(function(event) dispatch(rt, { type = "bot-event", event = event }) end)
			if alive(rt) then sync_timers(rt) end
		end)
	elseif not rt.bot then cancel(rt, "bot") end
end

local function load_blob(rt, path)
	local cx = context(rt)
	if not cx then return nil end
	local bytes = tern.fs.read(tern.plugin.data .. "/" .. path, MAX_IMAGE_BYTES)
	return cx:blob(bytes, mime(bytes))
end

local function notice(rt, warning)
	dispatch(rt, { type = "notice", warning = warning })
end

poll_tasks = function(rt)
	local tasks, changed = {}, false
	for _, m in rt.model.items do
		if not status.settled(m) and (m.disposition == "doing" or (m.task and m.task.request_id)) then
			local task = bridge.task(m.id)
			tasks[m.id] = task
			local phase = if task then task.state else "closed"
			local raw = if task and type(task.result) == "string" then task.result else nil
			changed = changed or not m.task or m.task.phase ~= phase or m.task.raw ~= raw
		end
	end
	if changed then dispatch(rt, { type = "tasks", tasks = tasks }) end
	bridge.prune_auto()
end

-- Effects a person triggers or needs to see; there is nowhere to show them without a pane.
local NEEDS_PANE = { open = true, copy = true, toast = true, focus = true, ["open-task"] = true }

execute = function(rt, effect)
	local ty = effect.type
	local cx = context(rt)
	if NEEDS_PANE[ty] and not cx then return end
	if ty == "save" then store.save(rt.model)
	elseif ty == "save-now" then store.save_now(rt.model)
	elseif ty == "record" then store.record(effect.ids, effect.outcome)
	elseif ty == "setting" then settings.set(effect.id, effect.value)
	elseif ty == "rule" then settings.set_rule(effect.chat_id, effect.rule)
	elseif ty == "stars" then store.set_stars(effect.list)
	elseif ty == "open" then cx:open(effect.url)
	elseif ty == "copy" then cx:copy(effect.text)
	elseif ty == "toast" then cx:toast("error", effect.title, effect.detail or "")
	elseif ty == "focus" then
		local id = if effect.mode == "draft" then ids.DRAFT_ID elseif effect.mode == "command" then ids.COMMAND_ID
			elseif effect.mode == "setting" then ids.field_control_id(effect.setting) else tern.json.null
		cx:frame({ { "focus", id } })
	elseif ty == "fetch" then
		fetch.run(effect, function(event)
			event.decisions = store.decisions()
			dispatch(rt, event)
		end)
	elseif ty == "history-search" then
		lark.search({ filters = { "--is-at-me" }, token = effect.token }, function(page, err)
			dispatch(rt, { type = "history", name = "result", gen = effect.gen, page = page, error = err })
		end)
	elseif ty == "chat-settings" then
		lark.chat_settings(effect.ids, function(found, err)
			dispatch(rt, { type = "chat-settings", gen = effect.gen, ids = effect.ids, fresh = effect.fresh, found = found, error = err })
		end)
	elseif ty == "read-status" then
		if #effect.ids == 0 then dispatch(rt, { type = "read-status", gen = effect.gen, found = {}, added = effect.added }); return end
		lark.read_status(effect.ids, function(found, err)
			dispatch(rt, { type = "read-status", gen = effect.gen, found = found, error = err, added = effect.added })
		end)
	elseif ty == "thread" then
		lark.history(effect.chat_id, effect.count, effect.until_time, function(messages, err)
			dispatch(rt, { type = "thread", id = effect.id, gen = effect.gen, latest = effect.latest, messages = messages, error = err })
		end)
	elseif ty == "image" then
		local function loaded(path, err)
			if not alive(rt) then return end
			local ok, blob = false, nil
			if path then ok, blob = pcall(load_blob, rt, path) end
			dispatch(rt, { type = "image", key = effect.key, path = if ok then path else nil, blob = if ok then blob else nil,
				error = err or (if path and not ok then tostring(blob) else nil) })
		end
		local cached = rt.model.images[effect.key]
		if cached and cached.path then loaded(cached.path, nil) else lark.download_image(effect.message_id, effect.key, loaded) end
	elseif ty == "analyze" then
		local thread = effect.matter.thread or {}
		local through = if #thread > 0 then thread[#thread].id else nil
		local finished = false
		local token = ai.analyze(effect.matter, effect.extras, effect.images, function(w) notice(rt, w) end, function(judgment, session, cost, err, run)
			finished = true
			local turn = rt.turns[effect.id]
			if turn and turn.gen == effect.gen then rt.turns[effect.id] = nil end
			dispatch(rt, { type = "analyzed", id = effect.id, gen = effect.gen, judgment = judgment, session = session,
				cost = cost, error = err, run = run, through = through })
		end)
		if token and not finished then rt.turns[effect.id] = { gen = effect.gen, token = token } end
	elseif ty == "stop-analysis" then
		local turn = rt.turns[effect.id]
		if turn and turn.gen == effect.gen then omp.stop(turn.token) end
	elseif ty == "converse" then
		ai.converse(effect.matter, effect.extras, effect.current, effect.said, function(w) notice(rt, w) end, function(reply, change, session, cost, err, run)
			dispatch(rt, { type = "conversed", id = effect.id, gen = effect.gen, reply = reply, change = change,
				session = session, cost = cost, error = err, run = run })
		end)
	elseif ty == "prepare" or ty == "context" then
		ai.prepare_task(effect.matter, effect.task, function(w) notice(rt, w) end, function(prompt, cost, err, needs)
			dispatch(rt, { type = if ty == "context" then "context-prepared" else "prepared",
				id = effect.id, gen = effect.gen, revision = effect.revision,
				prompt = prompt, cost = cost, error = err, needs = needs })
		end)
	elseif ty == "write-task" then
		assert(effect.default_workspace_setting == settings.get("workspace"), "默认 Workspace 已变化，请重新确认")
		local env = launch.prepare()
		assert(not env.warning, env.warning or "默认 Workspace 不可用，请重新确认")
		-- Validate routing before the confirmation can become visible to the window.
		local cwd = launch.task_workspace(effect.workspace, env.cwd)
		effect.default_workspace = env.cwd
		local request = bridge.start(effect.id, effect, function(record)
			workbench_events.confirmed(record, rt.model.cfg.now, effect.session)
		end)
		if effect.auto then bridge.auto_open(effect.id, request.request_id) end
		dispatch(rt, { type = "task-written", id = effect.id, revision = effect.revision,
			request_id = request.request_id, workspace = cwd, default_workspace = request.default_workspace })
	elseif ty == "workbench-event" then
		workbench_events.append(effect.event)
		dispatch(rt, { type = "event-saved" })
	elseif ty == "delete-task" then
		if bridge.request(effect.id) or bridge.state(effect.id) then
			bridge.remove(effect.id)
			-- Only the window deletes its result record; host open() routes links.
			if cx then cx:open(bridge.CLEANUP_LINK .. effect.id) end
		end
	elseif ty == "open-task" then cx:open(bridge.LINK .. effect.id)
	elseif ty == "poll-tasks" then poll_tasks(rt)
	elseif ty == "spoken" then
		lark.search({ filters = { "--chat-id", effect.chat_id, "--sender", effect.me }, since = effect.since }, function(data, err)
			if err or not data then return end
			local since = os.date("%Y-%m-%d %H:%M", effect.since)
			for _, message in data.messages do
				if not message.deleted and tostring(message.create_time or "") >= since then
					dispatch(rt, { type = "spoken", id = effect.id, revision = effect.revision, text = markup.clean(tostring(message.content or "")) })
					break
				end
			end
		end)
	elseif ty == "forget" then omp.forget(effect.session)
	elseif ty == "bot-bind" then
		tern.kv.set("bot_owner", { profile = settings.get("bot_profile"), open_id = effect.open_id })
	elseif ty == "bot-fetch" then
		local profile = settings.get("bot_profile")
		lark.message(effect.target, function(message, err)
			if settings.get("bot_profile") ~= profile then return end
			if message and (message.chat_id ~= effect.chat_id or message.deleted) then
				message, err = nil, "指令目标已撤回或不在同一会话，未启动分析。"
			end
			dispatch(rt, { type = "bot-message", message = message, error = err, instruction = effect.instruction, command = effect.command })
		end)
	elseif ty == "continue" then dispatch(rt, { type = "continue" })
	elseif ty == "wake" then
		cancel(rt, "wake")
		if effect.at then timer(rt, "wake", math.max(1, effect.at - os.time() + 1) * 1000, function() dispatch(rt, { type = "wake" }) end) end
	else error("Unknown workbench effect: " .. tostring(ty)) end
end

local function failed_effect(rt, effect, err)
	local ty = effect.type
	local event_type = ({ fetch = "fetched", ["read-status"] = "read-status", thread = "thread", analyze = "analyzed", converse = "conversed",
		prepare = "prepared", context = "context-prepared" })[ty]
	if event_type then
		dispatch(rt, { type = event_type, id = effect.id, gen = effect.gen, revision = effect.revision,
			latest = effect.latest, error = tostring(err), found = {}, added = effect.added })
	elseif ty == "image" then dispatch(rt, { type = "image", key = effect.key, error = tostring(err) })
	elseif ty == "history-search" then dispatch(rt, { type = "history", name = "result", gen = effect.gen, error = tostring(err) })
	elseif ty == "write-task" then
		dispatch(rt, { type = "task-write-failed", id = effect.id, revision = effect.revision, error = tostring(err) })
	elseif ty == "workbench-event" then
		dispatch(rt, { type = "event-failed", error = tostring(err) })
	elseif ty == "chat-settings" then
		dispatch(rt, { type = "chat-settings", gen = effect.gen, ids = effect.ids, fresh = effect.fresh, found = {}, error = tostring(err) })
	elseif ty == "bot-fetch" then
		dispatch(rt, { type = "bot-message", error = tostring(err), instruction = effect.instruction })
	else error(err, 0) end
end

-- Queue reentrant callbacks (including synchronous cached results) until the
-- current event and its effects finish. Model updates are never interleaved.
dispatch = function(rt, event)
	if not alive(rt) then return false end
	table.insert(rt.events, event)
	if rt.dispatching then return true end
	rt.dispatching = true
	local handled = false
	while #rt.events > 0 do
		local next_event = table.remove(rt.events, 1)
		rt.model.cfg = config()
		rt.model.cfg.visible = context(rt) ~= nil
		rt.model.cfg.bot_id = if rt.bot and rt.bot.profile == rt.model.cfg.settings.bot_profile then rt.bot.open_id else nil
		local effects, changed = update.apply(rt.model, next_event)
		handled = handled or changed
		for _, effect in effects do
			local ok, err = pcall(execute, rt, effect)
			if not ok then failed_effect(rt, effect, err) end
		end
	end
	rt.dispatching = false
	sync_timers(rt)
	-- Closed panes are dropped before rendering; with none open the work still went on.
	if handled and context(rt) then
		for _, pane in rt.panes do pane:render() end
	end
	return handled
end

-- Started when the plugin loads, so messages keep coming with every workbench closed.
function runtime.start()
	if active then return active end
	local cfg = config()
	local model = store.load(cfg) or snapshot.empty(cfg)
	local ids = {}; for _, m in model.items do table.insert(ids, m.id) end
	bridge.migrate(ids)
	-- Recover a publication interrupted before task-written reached the snapshot;
	-- its confirmation already exists. This never starts or reconfirms old work.
	for _, m in model.items do
		local request = bridge.request(m.id)
		if m.task and not m.task.request_id and task_rules.valid_request(request)
			and request.matter_id == m.id and m.task.revision == request.revision then
			m.task.request_id, m.task.default_workspace = request.request_id, request.default_workspace
			m.task.workspace = task_rules.workspace(request.workspace, request.default_workspace)
			m.task.task_text, m.task.title = request.task_text, request.title
		end
	end
	local rt = { model = model, panes = {}, timers = {}, events = {}, dispatching = false, turns = {} }
	active = rt
	dispatch(rt, { type = "init" })
	return rt
end

function runtime.attach(cx, saved)
	local rt = runtime.start()
	if not context(rt) then
		-- Image handles belong to the pane that made them; the first pane after
		-- none rebuilds them from the downloaded files.
		for _, image in rt.model.images do image.blob = nil end
		if saved and views.known(saved.view) then rt.model.view = saved.view end
	end
	rt.panes[cx.pane] = cx
	dispatch(rt, { type = "init" })
	return rt
end

function runtime.render(rt, cx)
	rt.panes[cx.pane] = cx
	return ui.render(rt.model, update.facts(rt.model), cx)
end

function runtime.event(rt, ev, cx)
	rt.panes[cx.pane] = cx
	local event = input.event(rt.model, ev)
	if event then dispatch(rt, event) end
end

function runtime.key(rt, key, cx)
	rt.panes[cx.pane] = cx
	local event = input.key(rt.model, key)
	return if event then dispatch(rt, event) else rt.model.dialog ~= nil
end

function runtime.title(rt)
	return views.tab_name(rt.model.items, rt.model.loading, rt.model.problem)
end

function runtime.save(rt)
	store.save(rt.model)
	return { view = rt.model.view }
end

return runtime

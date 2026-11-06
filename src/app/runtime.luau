-- The host runtime owns IO and lifecycle, not domain transitions. Every result
-- enters core/update as an event. A single live model is shared by the plugin's
-- workbench panes, so stale panes cannot overwrite each other's snapshot.
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

local runtime = {}
local active = nil
local MAX_IMAGE_BYTES = 20 * 1024 * 1024

local function config()
	return { settings = settings.all(), rules = settings.rules(), stars = store.stars(), now = os.time(), home = tern.getenv("HOME") }
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
	if active ~= rt or rt.closed then return false end
	if context(rt) then return true end
	rt.closed = true
	for name in rt.timers do cancel(rt, name) end
	store.close(rt.model)
	active = nil
	return false
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
	for _, m in rt.model.items do if m.disposition == "doing" then tasked = true; break end end
	if tasked and not rt.timers.tasks then
		timer(rt, "tasks", 3000, function() poll_tasks(rt); if alive(rt) then sync_timers(rt) end end)
	elseif not tasked then cancel(rt, "tasks") end
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
		if m.disposition == "doing" then
			local task = bridge.task(m.id)
			tasks[m.id] = task
			local phase = if task then task.state else "closed"
			local raw = if task and type(task.result) == "string" then task.result else nil
			changed = changed or not m.task or m.task.phase ~= phase or m.task.raw ~= raw
		end
	end
	if changed then dispatch(rt, { type = "tasks", tasks = tasks }) end
end

execute = function(rt, effect)
	local ty = effect.type
	local cx = context(rt)
	if not cx then return end
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
		ai.analyze(effect.matter, effect.extras, effect.images, function(w) notice(rt, w) end, function(judgment, session, cost, err, run)
			dispatch(rt, { type = "analyzed", id = effect.id, gen = effect.gen, judgment = judgment, session = session,
				cost = cost, error = err, run = run, through = through })
		end)
	elseif ty == "converse" then
		ai.converse(effect.matter, effect.extras, effect.current, effect.said, function(w) notice(rt, w) end, function(reply, change, session, cost, err)
			dispatch(rt, { type = "conversed", id = effect.id, gen = effect.gen, reply = reply, change = change, session = session, cost = cost, error = err })
		end)
	elseif ty == "prepare" then
		ai.prepare_task(effect.matter, effect.task, function(w) notice(rt, w) end, function(prompt, cost, err)
			dispatch(rt, { type = "prepared", id = effect.id, gen = effect.gen, prompt = prompt, cost = cost, error = err })
		end)
	elseif ty == "write-task" then bridge.set_task(effect.id, { prompt = effect.prompt, title = effect.title, state = "starting" })
	elseif ty == "delete-task" then bridge.set_task(effect.id, nil)
	elseif ty == "open-task" then cx:open(bridge.LINK .. effect.id)
	elseif ty == "reopen-task" then
		local task = bridge.task(effect.id)
		if task then task.state = "starting"; bridge.set_task(effect.id, task); cx:open(bridge.LINK .. effect.id)
		else dispatch(rt, { type = "task-missing", id = effect.id }) end
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
	elseif ty == "continue" then dispatch(rt, { type = "continue" })
	elseif ty == "wake" then
		cancel(rt, "wake")
		if effect.at then timer(rt, "wake", math.max(1, effect.at - os.time() + 1) * 1000, function() dispatch(rt, { type = "wake" }) end) end
	else error("Unknown workbench effect: " .. tostring(ty)) end
end

local function failed_effect(rt, effect, err)
	local ty = effect.type
	local event_type = ({ fetch = "fetched", ["read-status"] = "read-status", thread = "thread", analyze = "analyzed", converse = "conversed", prepare = "prepared" })[ty]
	if event_type then
		dispatch(rt, { type = event_type, id = effect.id, gen = effect.gen, latest = effect.latest, error = tostring(err), found = {}, added = effect.added })
	elseif ty == "image" then dispatch(rt, { type = "image", key = effect.key, error = tostring(err) })
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
		local effects, changed = update.apply(rt.model, next_event)
		handled = handled or changed
		for _, effect in effects do
			local ok, err = pcall(execute, rt, effect)
			if not ok then failed_effect(rt, effect, err) end
		end
	end
	rt.dispatching = false
	sync_timers(rt)
	if handled then
		for _, pane in rt.panes do pane:render() end
	end
	return handled
end

function runtime.attach(cx, saved)
	if active and not active.closed then
		active.panes[cx.pane] = cx
		return active
	end
	local cfg = config()
	local model = store.load(cfg) or snapshot.empty(cfg)
	if saved and views.known(saved.view) then model.view = saved.view end
	local rt = { model = model, panes = { [cx.pane] = cx }, timers = {}, events = {}, dispatching = false, closed = false }
	active = rt
	-- Recreate only blobs for the selected matter, without fetching chat or images.
	for _, m in model.items do
		if m.id == model.selected and cfg.settings.show_images then
			for _, message in m.thread or {} do
				for _, key in markup.images(message.content, 4) do
					local image = model.images[key]
					if image and image.path then
						local ok, blob = pcall(load_blob, rt, image.path)
						if ok then image.blob = blob else model.images[key] = nil end
					end
				end
			end
		end
	end
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

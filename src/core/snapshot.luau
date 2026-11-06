--!strict
-- The durable workbench format. Migration and validation are pure: restoring
-- never starts work, reads settings, downloads images, or changes the input.
local types = require("./types")
local schema = require("../shared/schema")

type Model = types.Model
type Matter = types.Matter
type Config = types.Config

local snapshot = {}
local ANALYSIS_INTERRUPTED = "分析在重载时中断，未自动重试。按 r 手动重试。"
local CHAT_INTERRUPTED = "对话在重载时中断，未自动续跑。请检查会话后重新发起。"

local function invalid(path: string, expected: string): never
	error("Invalid inbox snapshot at " .. path .. ": expected " .. expected, 0)
end

local function object(value: any, path: string): any
	if type(value) ~= "table" then
		invalid(path, "table")
	end
	return value
end

local function array(value: any, path: string): any
	object(value, path)
	local count = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			invalid(path, "dense array")
		end
		count += 1
	end
	for i = 1, count do
		if value[i] == nil then
			invalid(path, "dense array")
		end
	end
	return value
end

local function string_value(value: any, path: string, fallback: string?): string
	if value == nil and fallback ~= nil then
		return fallback
	elseif type(value) ~= "string" then
		invalid(path, "string")
	end
	return value
end

local function optional_string(value: any, path: string): string?
	return if value == nil then nil else string_value(value, path)
end

local function boolean_value(value: any, path: string, fallback: boolean?): boolean
	if value == nil and fallback ~= nil then
		return fallback
	elseif type(value) ~= "boolean" then
		invalid(path, "boolean")
	end
	return value
end

local function optional_boolean(value: any, path: string): boolean?
	return if value == nil then nil else boolean_value(value, path)
end

local function number_value(value: any, path: string): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		invalid(path, "finite number")
	end
	return value
end

local function optional_number(value: any, path: string): number?
	return if value == nil then nil else number_value(value, path)
end

local function count_value(value: any, path: string, fallback: number?): number
	local n = if value == nil and fallback ~= nil then fallback else number_value(value, path)
	if n < 0 or n % 1 ~= 0 then
		invalid(path, "nonnegative integer")
	end
	return n
end

local function choice(value: any, path: string, choices: { string }, fallback: string?): any
	local s = string_value(value, path, fallback)
	if not table.find(choices, s) then
		invalid(path, table.concat(choices, " | "))
	end
	return s
end

-- Dynamic service payloads (agenda, notification preferences and run metadata)
-- are JSON data too, never shared mutable references or executable handles.
local function copy_data(value: any, path: string, visiting: { [any]: boolean }?): any
	local kind = type(value)
	if value == nil or kind == "string" or kind == "boolean" then
		return value
	elseif kind == "number" then
		return number_value(value, path)
	elseif kind ~= "table" then
		invalid(path, "JSON data")
	end
	local seen = visiting or {}
	if seen[value] then
		invalid(path, "acyclic JSON data")
	end
	seen[value] = true
	local copied = {}
	local numeric, named = 0, 0
	for key, child in value do
		if type(key) == "number" and key >= 1 and key % 1 == 0 then
			numeric += 1
		elseif type(key) == "string" then
			named += 1
		else
			invalid(path, "string keys or dense array")
		end
		copied[key] = copy_data(child, path .. "." .. tostring(key), seen)
	end
	if numeric > 0 then
		if named > 0 then
			invalid(path, "object or dense array, not both")
		end
		array(copied, path)
	end
	seen[value] = nil
	return copied
end

function snapshot.empty(cfg: Config): Model
	return {
		cfg = cfg, items = {}, view = "pending", source = "all",
		command = "", command_cursor = 0, draft_cursor = 0,
		settings_cursor = schema.FIELDS[1].id, field_cursor = 0,
		log = {}, loading = false, loading_more = false,
		backlog_marked = false, cursors = {}, images = {}, gen = 0, loaded = false,
	}
end

local function read_judgment(value: any, path: string, legacy: boolean): types.Judgment?
	if value == nil then
		return nil
	end
	local j = object(value, path)
	local task = object(if legacy and j.task == nil then {} else j.task, path .. ".task")
	local fallback = if legacy then "" else nil
	return {
		kind = choice(if legacy then j.state else j.kind, path .. ".kind", { "fyi", "reply", "deep" }),
		pri = choice(j.pri, path .. ".pri", { "P0", "P1", "P2", "P3" }),
		summary = string_value(j.summary, path .. ".summary", fallback),
		why = string_value(j.why, path .. ".why", fallback),
		draft = string_value(j.draft, path .. ".draft", fallback),
		risk = string_value(j.risk, path .. ".risk", fallback),
		task = {
			title = string_value(task.title, path .. ".task.title", fallback),
			prompt = string_value(task.prompt, path .. ".task.prompt", fallback),
		},
		manual = boolean_value(j.manual, path .. ".manual", if legacy then false else nil),
	}
end

local function disposition(value: any, path: string, legacy: boolean): types.Disposition?
	if value == nil then
		return nil
	end
	return choice(if legacy and value == "sent" then "replied" else value,
		path, { "handoff", "snoozed", "doing", "archived", "replied" })
end

local function read_thread(value: any, path: string, legacy: boolean): { types.ThreadMessage }?
	if value == nil then
		return nil
	end
	local thread = {}
	local undated = false
	for i, raw in array(value, path) do
		local p = path .. "[" .. tostring(i) .. "]"
		local message = object(raw, p)
		local at = string_value(message.time, p .. ".time")
		undated = undated or (legacy and string.match(at, "^%d%d:%d%d$") ~= nil)
		table.insert(thread, {
			id = string_value(message.id, p .. ".id"),
			sender = string_value(message.sender, p .. ".sender"),
			time = at, content = string_value(message.content, p .. ".content"),
			deleted = boolean_value(message.deleted, p .. ".deleted", if legacy then false else nil),
			mine = boolean_value(message.mine, p .. ".mine", if legacy then false else nil),
		})
	end
	-- Old HH:MM-only context has no trustworthy date. Runtime may fetch it when
	-- explicitly requested, just as the old restore did; it is not fetched here.
	return if undated then nil else thread
end

local function read_item(value: any, path: string, legacy: boolean): Matter
	local item = object(value, path)
	local a = if legacy then item else object(item.analysis, path .. ".analysis")
	local phase = choice(if legacy then item.agent else a.phase, path .. ".analysis.phase",
		{ "queued", "running", "failed", "done" }, if legacy then (if item.analysis then "done" else "queued") else nil)
	local folded = {}
	local seen_ids = { [string_value(item.id, path .. ".id")] = true }
	for i, id in array(item.folded, path .. ".folded") do
		local valid = string_value(id, path .. ".folded[" .. tostring(i) .. "]")
		if not seen_ids[valid] then
			seen_ids[valid] = true
			table.insert(folded, valid)
		end
	end
	local talk = {}
	for i, raw in array(if legacy and item.talk == nil then {} else item.talk, path .. ".talk") do
		local p = path .. ".talk[" .. tostring(i) .. "]"
		local entry = object(raw, p)
		table.insert(talk, { text = string_value(entry.text, p .. ".text"), me = optional_boolean(entry.me, p .. ".me") })
	end
	local edits = if legacy then { reply = item.edited, task = item.task_edited } else object(item.edits, path .. ".edits")
	local task = if legacy then nil else item.task
	if legacy and (item.triage == "doing" or item.task_state ~= nil or item.result ~= nil or item.task_raw ~= nil or item.task_new ~= nil) then
		task = {
			phase = if item.task_state == nil then "closed" else item.task_state,
			result = item.result, raw = item.task_raw,
			new_messages = if item.task_new == nil then 0 else item.task_new,
		}
	end
	local parsed_task: types.Task? = nil
	if task ~= nil then
		object(task, path .. ".task")
		parsed_task = {
			phase = choice(task.phase, path .. ".task.phase", { "starting", "working", "waiting", "done", "closed" }),
			result = optional_string(task.result, path .. ".task.result"),
			raw = optional_string(task.raw, path .. ".task.raw"),
			new_messages = count_value(task.new_messages, path .. ".task.new_messages"),
		}
	end
	local interrupted = phase == "running"
	local analysis_error = optional_string(if legacy then item.agent_error else a.error, path .. ".analysis.error")
	local fallback = if legacy then "" else nil
	return {
		id = string_value(item.id, path .. ".id"),
		revision = count_value(item.revision, path .. ".revision", if legacy then 0 else nil),
		chat_id = string_value(item.chat_id, path .. ".chat_id", fallback),
		chat = string_value(item.chat, path .. ".chat", fallback),
		chat_type = string_value(item.chat_type, path .. ".chat_type", if legacy then "group" else nil),
		name = string_value(item.name, path .. ".name", fallback),
		sender_id = string_value(item.sender_id, path .. ".sender_id", fallback),
		sender_type = choice(item.sender_type, path .. ".sender_type", { "user", "bot", "unknown" }, if legacy then "unknown" else nil),
		time = string_value(item.time, path .. ".time", fallback),
		content = string_value(item.content, path .. ".content", fallback),
		deleted = boolean_value(item.deleted, path .. ".deleted", if legacy then false else nil),
		link = optional_string(item.link, path .. ".link"),
		mention = boolean_value(item.mention, path .. ".mention", if legacy then false else nil),
		via = string_value(item.via, path .. ".via", if legacy then "群聊" else nil),
		folded = folded, latest_id = optional_string(item.latest_id, path .. ".latest_id"),
		is_read = optional_boolean(item.is_read, path .. ".is_read"),
		analysis = {
			phase = if interrupted then "failed" else phase, gen = 0,
			judgment = read_judgment(if legacy then item.analysis else a.judgment, path .. ".analysis.judgment", legacy),
			error = if interrupted then ANALYSIS_INTERRUPTED else analysis_error,
			session = optional_string(a.session, path .. ".analysis.session"),
			through = optional_string(if legacy then item.analyzed_through else a.through, path .. ".analysis.through"),
			settle_at = optional_number(a.settle_at, path .. ".analysis.settle_at"),
			backlog = boolean_value(a.backlog, path .. ".analysis.backlog", if legacy then false else nil),
			force = boolean_value(a.force, path .. ".analysis.force", if legacy then false else nil),
			reanalyze = false, run = copy_data(a.run, path .. ".analysis.run"),
		},
		disposition = disposition(if legacy then item.triage else item.disposition, path .. ".disposition", legacy),
		handoff_at = optional_number(item.handoff_at, path .. ".handoff_at"),
		spoken = optional_string(item.spoken, path .. ".spoken"),
		reopened = optional_string(item.reopened, path .. ".reopened"),
		task = parsed_task,
		edits = { reply = optional_string(edits.reply, path .. ".edits.reply"), task = optional_string(edits.task, path .. ".edits.task") },
		talk = talk, thread = read_thread(item.thread, path .. ".thread", legacy),
		thread_error = optional_string(item.thread_error, path .. ".thread_error"),
		hidden = false, no_agent = false,
	}
end

local function read_undo(value: any, legacy: boolean): types.Undo?
	if value == nil then
		return nil
	end
	local undo = object(value, "undo")
	local kind = choice(undo.kind, "undo.kind", { "triage", "rule" })
	local id = string_value(undo.id, "undo.id")
	if kind == "triage" then
		return { kind = "triage", id = id, previous = disposition(undo.previous, "undo.previous", legacy) }
	end
	local previous = nil
	if undo.previous ~= nil then
		local rule = object(undo.previous, "undo.previous")
		previous = { mode = string_value(rule.mode, "undo.previous.mode"), name = string_value(rule.name, "undo.previous.name") }
	end
	return { kind = "rule", id = id, chat_id = string_value(undo.chat_id, "undo.chat_id"), previous = previous }
end

function snapshot.decode(value: any, cfg: Config): Model?
	if value == nil then
		return nil
	end
	local stored = object(value, "root")
	if stored.version ~= 1 and stored.version ~= 2 then
		error("Unsupported inbox snapshot version: " .. tostring(stored.version), 0)
	end
	local legacy = stored.version == 1
	local model = snapshot.empty(cfg)
	local seen: { [string]: boolean } = {}
	for i, raw in array(stored.items, "items") do
		local item = read_item(raw, "items[" .. tostring(i) .. "]", legacy)
		if item.id == "" or seen[item.id] then
			invalid("items[" .. tostring(i) .. "].id", "unique nonempty message id")
		end
		seen[item.id] = true
		table.insert(model.items, item)
	end
	model.loaded = true
	model.me = optional_string(stored.me, "me")
	model.view = string_value(stored.view, "view", "pending")
	model.source = choice(stored.source, "source", { "all", "mention", "dm" }, "all")
	if legacy and (model.view == "mention" or model.view == "dm") then
		model.source, model.view = model.view, "pending"
	elseif legacy and model.view == "settings" then
		model.page, model.view = "settings", "pending"
	end
	model.person = optional_string(stored.person, "person")
	model.selected = optional_string(stored.selected, "selected")
	if stored.page ~= nil then
		model.page = choice(stored.page, "page", { "settings", "history" })
	end
	if stored.mode ~= nil then
		model.mode = choice(stored.mode, "mode", { "draft", "command", "setting" })
	end
	model.command = string_value(stored.command, "command", "")
	model.command_cursor = count_value(stored.command_cursor, "command_cursor", 0)
	model.draft_cursor = count_value(stored.draft_cursor, "draft_cursor", 0)
	model.settings_cursor = string_value(stored.settings_cursor, "settings_cursor", model.settings_cursor)
	model.field_cursor = count_value(stored.field_cursor, "field_cursor", 0)
	model.dialog = optional_string(stored.dialog, "dialog")
	model.undo = read_undo(stored.undo, legacy)
	model.problem = optional_string(stored.problem, "problem")
	model.runtime_warning = optional_string(stored.runtime_warning, "runtime_warning")
	model.last_refresh = optional_number(stored.last_refresh, "last_refresh")
	model.backlog_marked = boolean_value(stored.backlog_marked, "backlog_marked", false)
	model.agenda = copy_data(stored.agenda, "agenda")
	if stored.chat_settings ~= nil then
		model.chat_settings = copy_data(object(stored.chat_settings, "chat_settings"), "chat_settings")
	end
	for i, raw in array(if stored.log == nil then {} else stored.log, "log") do
		local path = "log[" .. tostring(i) .. "]"
		local entry = object(raw, path)
		table.insert(model.log, { t = string_value(entry.t, path .. ".t"), who = string_value(entry.who, path .. ".who"), text = string_value(entry.text, path .. ".text") })
	end
	for key, raw in object(if stored.cursors == nil then {} else stored.cursors, "cursors") do
		string_value(key, "cursors key")
		local path = "cursors." .. key
		local cursor = object(raw, path)
		model.cursors[key] = {
			token = optional_string(cursor.token, path .. ".token"), since = optional_number(cursor.since, path .. ".since"),
			paged = optional_boolean(cursor.paged, path .. ".paged"), exhausted = optional_boolean(cursor.exhausted, path .. ".exhausted"),
		}
	end
	local images = if legacy then stored.image_paths else stored.images
	for key, raw in object(if images == nil then {} else images, "images") do
		string_value(key, "images key")
		local path = "images." .. key
		model.images[key] = { path = string_value(if legacy then raw else object(raw, path).path, path .. ".path") }
	end
	local interrupted_chat = optional_string(stored.interrupted_chat, "interrupted_chat")
	if interrupted_chat then
		for _, item in model.items do
			if item.id == interrupted_chat then
				table.insert(item.talk, { text = CHAT_INTERRUPTED })
				break
			end
		end
	end
	return model
end

local function encode_item(item: Matter): any
	local a = item.analysis
	return {
		id = item.id, revision = item.revision, chat_id = item.chat_id, chat = item.chat, chat_type = item.chat_type,
		name = item.name, sender_id = item.sender_id, sender_type = item.sender_type, time = item.time,
		content = item.content, deleted = item.deleted, link = item.link, mention = item.mention, via = item.via,
		folded = table.clone(item.folded), latest_id = item.latest_id, is_read = item.is_read,
		analysis = {
			phase = a.phase, judgment = copy_data(a.judgment, "analysis.judgment"), error = a.error, session = a.session,
			through = a.through, settle_at = a.settle_at, backlog = a.backlog, force = a.force,
			run = copy_data(a.run, "analysis.run"),
		},
		disposition = item.disposition, handoff_at = item.handoff_at, spoken = item.spoken, reopened = item.reopened,
		task = if item.task then { phase = item.task.phase, result = item.task.result, raw = item.task.raw, new_messages = item.task.new_messages } else nil,
		edits = { reply = item.edits.reply, task = item.edits.task }, talk = copy_data(item.talk, "talk"),
		thread = copy_data(item.thread, "thread"), thread_error = item.thread_error,
	}
end

function snapshot.encode(model: Model): any
	local stored: any = {
		version = 2, items = {}, images = {}, interrupted_chat = model.talking,
		me = model.me, view = model.view, source = model.source, person = model.person, selected = model.selected,
		page = model.page, mode = model.mode, command = model.command, command_cursor = model.command_cursor,
		draft_cursor = model.draft_cursor, settings_cursor = model.settings_cursor, field_cursor = model.field_cursor,
		dialog = model.dialog, undo = copy_data(model.undo, "undo"), log = copy_data(model.log, "log"),
		problem = model.problem, runtime_warning = model.runtime_warning, last_refresh = model.last_refresh,
		backlog_marked = model.backlog_marked, agenda = copy_data(model.agenda, "agenda"),
		chat_settings = copy_data(model.chat_settings, "chat_settings"), cursors = copy_data(model.cursors, "cursors"),
	}
	for _, item in model.items do
		table.insert(stored.items, encode_item(item))
	end
	for key, image in model.images do
		if image.path then
			stored.images[key] = { path = image.path }
		end
	end
	return stored
end

return snapshot

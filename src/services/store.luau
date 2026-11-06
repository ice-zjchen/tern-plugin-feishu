-- What the workbench keeps in tern.kv: the queue snapshot (written at most once
-- per SAVE_DELAY_MS, never callbacks, cx handles, timers or blobs), per-message
-- outcomes and starred senders.
local tern = require("tern")
local store = {}
local SAVE_DELAY_MS = 500
local DECISION_TTL = 30 * 86400
local KEY = "inbox_snapshot"
local VERSION = 1
local ITEM_FIELDS = {
	"id", "chat_id", "chat", "chat_type", "name", "sender_id", "sender_type",
	"time", "content", "deleted", "link", "mention", "via", "folded", "is_read",
	"agent", "agent_error", "analysis", "session", "edited", "task_edited", "talk",
	"thread", "thread_for_agent", "thread_error", "triage", "handoff_at", "spoken",
	"task_state", "task_raw", "result", "backlog", "force",
	"latest_id", "settle_at", "analyzed_through", "reopened", "task_new", "reanalyze", "run",
}
local STATE_FIELDS = {
	"me", "view", "person", "selected", "spent", "log", "agenda", "agenda_error",
	"chat_settings", "cursors", "backlog_marked", "last_refresh", "undo", "command",
	"problem", "runtime_warning", "source",
}

-- Per-message outcomes, so a refresh can restore them: id -> { s = outcome, t = epoch }.
function store.decisions(): { [string]: any }
	local stored = tern.kv.get("decisions")
	return if type(stored) == "table" then stored else {}
end

-- Records `outcome` (nil clears it) for `ids`, dropping entries older than the TTL.
function store.record(ids: { string }, outcome: string?)
	local stored = store.decisions()
	local now = os.time()
	for id, decision in stored do
		if type(decision) ~= "table" or now - (tonumber(decision.t) or 0) > DECISION_TTL then
			stored[id] = nil
		end
	end
	for _, id in ids do
		stored[id] = if outcome then { s = outcome, t = now } else nil
	end
	tern.kv.set("decisions", stored)
end

-- Starred senders: { { id, name } }.
function store.stars(): { any }
	local stored = tern.kv.get("stars")
	return if type(stored) == "table" then stored else {}
end

function store.set_stars(list: { any })
	tern.kv.set("stars", tern.json.array(list))
end

local function write(state: any)
	if not state.has_snapshot then
		return
	end
	local snapshot: any = { version = VERSION, items = {}, image_paths = {} }
	snapshot.interrupted_chat = state.talking
	for _, field in STATE_FIELDS do
		snapshot[field] = state[field]
	end
	for _, item in state.items do
		local stored = {}
		for _, field in ITEM_FIELDS do
			stored[field] = item[field]
		end
		table.insert(snapshot.items, stored)
	end
	for key, path in state.image_paths or {} do
		snapshot.image_paths[key] = path
	end
	for key, image in state.images do
		if image.path then
			snapshot.image_paths[key] = image.path
		end
	end
	tern.kv.set(KEY, snapshot)
end

-- Saves at once. For moments a reload must see, such as a turn about to start:
-- a snapshot that missed it would replay a turn that may already have used tools.
function store.save_now(state: any)
	state.save_pending = nil
	write(state)
end

-- Saves soon, folding a burst of changes into one write.
function store.save(state: any)
	if state.save_pending then
		return
	end
	state.save_pending = true
	tern.timer(SAVE_DELAY_MS, function()
		if state.save_pending then
			store.save_now(state)
		end
	end)
end

function store.restore(state: any): boolean
	local snapshot = tern.kv.get(KEY)
	if type(snapshot) ~= "table" or snapshot.version ~= VERSION or type(snapshot.items) ~= "table" then
		return false
	end
	for _, item in snapshot.items do
		if type(item) ~= "table" or type(item.id) ~= "string" or type(item.folded) ~= "table" then
			return false
		end
	end
	for _, field in STATE_FIELDS do
		if snapshot[field] ~= nil then
			state[field] = snapshot[field]
		end
	end
	state.items = snapshot.items
	state.image_paths = snapshot.image_paths or {}
	state.has_snapshot = true
	for _, item in state.items do
		-- Older snapshots kept only HH:MM; reload context rather than invent its date.
		for _, message in item.thread or {} do
			if string.match(tostring(message.time), "^%d%d:%d%d$") then
				item.thread, item.thread_for_agent = nil, nil
				break
			end
		end
		if item.agent == "running" then
			-- Never replay an interrupted turn: it may already have used tools.
			item.agent = "failed"
			item.agent_error = "分析在重载时中断，未自动重试。按 r 手动重试。"
		end
	end
	if snapshot.interrupted_chat then
		for _, item in state.items do
			if item.id == snapshot.interrupted_chat then
				item.talk = item.talk or {}
				table.insert(item.talk, { text = "对话在重载时中断，未自动续跑。请检查会话后重新发起。" })
			end
		end
	end
	return true
end

return store

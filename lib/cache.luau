-- Durable workbench state only: never callbacks, cx handles, timers or blobs.
local tern = require("tern")
local cache = {}
local KEY = "inbox_snapshot"
local VERSION = 1
local ITEM_FIELDS = {
	"id", "chat_id", "chat", "chat_type", "name", "sender_id", "sender_type",
	"time", "content", "deleted", "link", "mention", "via", "folded", "is_read",
	"agent", "agent_error", "analysis", "session", "edited", "task_edited", "talk",
	"thread", "thread_for_agent", "thread_error", "triage", "handoff_at", "spoken",
	"task_state", "task_raw", "result", "backlog", "force",
	"latest_id", "settle_at", "analyzed_through", "reopened", "task_new", "reanalyze",
}
local STATE_FIELDS = {
	"me", "view", "person", "selected", "spent", "log", "agenda", "agenda_error",
	"chat_settings", "truncated", "backlog_marked", "last_refresh", "undo", "command",
	"problem", "runtime_warning", "source",
}

function cache.save(state: any)
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

function cache.restore(state: any): boolean
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

return cache

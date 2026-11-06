-- The plugin's settings, kept in tern.kv under `settings` and `chat_rules`.
local tern = require("tern")
local schema = require("./schema")

local settings = {}

local function stored(): { [string]: any }
	local value = tern.kv.get("settings")
	return if type(value) == "table" then value else {}
end

function settings.get(id: string): any
	return schema.coerce(id, stored()[id])
end

-- Every setting's value.
function settings.all(): { [string]: any }
	local raw, out = stored(), {}
	for _, field in schema.FIELDS do
		out[field.id] = schema.coerce(field.id, raw[field.id])
	end
	return out
end

function settings.set(id: string, value: any)
	schema.field(id)
	local all = stored()
	all[id] = value
	tern.kv.set("settings", all)
end

-- Per-chat rules: chat id -> { mode = "hide" | "manual", name = chat name }.
function settings.rules(): { [string]: any }
	local value = tern.kv.get("chat_rules")
	return if type(value) == "table" then value else {}
end

function settings.set_rule(chat_id: string, rule: any)
	local all = settings.rules()
	all[chat_id] = rule
	tern.kv.set("chat_rules", all)
end

-- Settings written by earlier versions, carried over once.
do
	local all = stored()
	local changed = false
	if type(all.model) == "string" then
		-- One model for every turn became one per purpose.
		all.model_analysis = all.model_analysis or all.model
		all.model_chat = all.model_chat or all.model
		all.model_relevance = all.model_relevance or all.model
		all.model, changed = nil, true
	end
	if all.source_atall ~= nil then
		-- The switch this replaced kept @所有人 when on.
		if all.hide_atall == nil then
			all.hide_atall = all.source_atall == false
		end
		all.source_atall, changed = nil, true
	end
	if changed then
		tern.kv.set("settings", all)
	end
end

return settings

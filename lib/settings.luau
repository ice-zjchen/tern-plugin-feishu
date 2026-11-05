-- The workbench's settings, kept in tern.kv under `settings` and `chat_rules`.
-- FIELDS drives the settings page, its keyboard handling and the defaults.

local tern = require("tern")

local settings = {}

-- `column` is where a group sits on the settings page; j/k follow this order.
settings.GROUPS = {
	{ id = "agent", column = "left", number = "1", title = "Agent（omp）" },
	{ id = "environment", column = "left", number = "2", title = "模型与目录" },
	{ id = "sources", column = "right", number = "3", title = "消息来源" },
	{ id = "filters", column = "right", number = "4", title = "过滤" },
	{ id = "run", column = "right", number = "5", title = "运行" },
}

settings.FIELDS = {
	{ id = "agent_enabled", group = "agent", kind = "switch", default = true, label = "自动分析", hint = "关闭后按 g 才交给 omp" },
	{ id = "concurrency", group = "agent", kind = "choice", default = 2, choices = { 1, 2, 3, 5 }, label = "并发数" },
	{ id = "backlog", group = "agent", kind = "choice", default = 30, choices = { 0, 10, 30, 50, 100 }, label = "打开时分析积压" },
	{ id = "thread_size", group = "agent", kind = "choice", default = 10, choices = { 5, 10, 20, 50 }, label = "会话上下文条数" },
	{ id = "use_agenda", group = "agent", kind = "switch", default = true, label = "提供今日日程", hint = "需要日历权限" },
	{ id = "agent_images", group = "agent", kind = "switch", default = true, label = "把图片发给 omp", hint = "触发消息里的图片，最多 3 张" },

	{ id = "thinking", group = "environment", kind = "choice", default = "default", choices = { "default", "off", "low", "medium", "high" }, label = "思考强度" },
	{ id = "model", group = "environment", kind = "text", default = "", label = "模型", hint = "如 opus；留空用 omp 默认模型" },
	{ id = "workspace", group = "environment", kind = "text", default = "", label = "Workspace 目录", hint = "omp 启动目录，支持绝对路径或 ~/；留空或不存在时用插件数据目录" },
	{ id = "skills_dir", group = "environment", kind = "text", default = "", label = "Skills 目录", hint = "额外技能目录，相对 Workspace；留空用 omp 默认发现规则" },

	{ id = "source_mention", group = "sources", kind = "switch", default = true, label = "@我" },
	{ id = "source_dm", group = "sources", kind = "switch", default = true, label = "私聊" },
	{ id = "source_star", group = "sources", kind = "switch", default = true, label = "星标联系人" },

	{ id = "hide_atall", group = "filters", kind = "switch", default = false, label = "隐藏 @所有人", hint = "星标联系人发的也隐藏；同时 @我 的仍显示" },
	{ id = "hide_bots", group = "filters", kind = "switch", default = false, label = "隐藏机器人消息", hint = "用户和未知身份不受影响" },
	{ id = "hide_muted", group = "filters", kind = "switch", default = false, label = "隐藏免打扰的群", hint = "含已关闭提醒的 @所有人；需读取群个人设置权限" },
	{ id = "ignore_keywords", group = "filters", kind = "text", default = "", label = "按群名隐藏", hint = "逗号分隔的关键词，如 notify,告警" },

	{ id = "show_images", group = "run", kind = "switch", default = true, label = "显示图片", hint = "关闭后不下载，只显示 [图片]" },
	{ id = "poll_minutes", group = "run", kind = "choice", default = 3, choices = { 0, 1, 3, 10, 30 }, label = "自动刷新（分钟）" },
	{ id = "lookback_days", group = "run", kind = "choice", default = 2, choices = { 1, 2, 3, 7 }, label = "检索最近几天" },
	{ id = "send_delay", group = "run", kind = "choice", default = 5, choices = { 3, 5, 10, 30 }, label = "发送前可撤销的秒数" },
}

local BY_ID = {}
for _, field in settings.FIELDS do
	BY_ID[field.id] = field
end

function settings.field(id: string): any
	return BY_ID[id]
end

local function stored(): { [string]: any }
	local value = tern.kv.get("settings")
	return if type(value) == "table" then value else {}
end

function settings.get(id: string): any
	local value = stored()[id]
	local field = BY_ID[id]
	if value == nil then
		-- The switch this replaced kept @所有人 when on.
		if id == "hide_atall" then
			return stored().source_atall == false
		end
		return field.default
	end
	-- A value from another version, or one a choice no longer offers, is dropped.
	if type(value) ~= type(field.default) or (field.choices and not table.find(field.choices, value)) then
		return field.default
	end
	return value
end

function settings.set(id: string, value: any)
	local all = stored()
	all[id] = value
	tern.kv.set("settings", all)
end

-- The next value of a switch or choice.
function settings.cycle(id: string, direction: number?)
	local field = BY_ID[id]
	if field.kind == "switch" then
		settings.set(id, not settings.get(id))
	elseif field.kind == "choice" then
		local at = table.find(field.choices, settings.get(id)) or 1
		settings.set(id, field.choices[(at - 1 + (direction or 1)) % #field.choices + 1])
	end
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

function settings.keywords(): { string }
	local words = {}
	for word in string.gmatch(settings.get("ignore_keywords"), "[^,，%s]+") do
		table.insert(words, string.lower(word))
	end
	return words
end

return settings

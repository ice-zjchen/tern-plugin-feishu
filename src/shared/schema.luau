--!strict
-- The settings page's groups and fields, and how a stored value is read back.
-- FIELDS drives the page, its keyboard handling and the defaults.

local schema = {}

export type Field = {
	id: string, group: string, kind: "switch" | "choice" | "text", default: any,
	choices: { any }?, label: string, hint: string?,
}

-- `column` is where a group sits on the settings page; j/k follow this order.
schema.GROUPS = {
	{ id = "agent", column = "left", number = "1", title = "AI 分析" },
	{ id = "environment", column = "left", number = "2", title = "模型与目录" },
	{ id = "sources", column = "right", number = "3", title = "消息来源" },
	{ id = "filters", column = "right", number = "4", title = "过滤" },
	{ id = "run", column = "right", number = "5", title = "运行" },
}

schema.FIELDS = ({
	{ id = "agent_enabled", group = "agent", kind = "switch", default = true, label = "自动分析", hint = "关闭后按 g 才让 AI 分析" },
	{ id = "concurrency", group = "agent", kind = "choice", default = 2, choices = { 1, 2, 3, 5 }, label = "并发数" },
	{ id = "backlog", group = "agent", kind = "choice", default = 30, choices = { 0, 10, 30, 50, 100 }, label = "打开时分析积压" },
	{ id = "thread_size", group = "agent", kind = "choice", default = 10, choices = { 5, 10, 20, 50 }, label = "会话上下文条数" },
	{ id = "use_agenda", group = "agent", kind = "switch", default = true, label = "提供今日日程", hint = "需要日历权限" },
	{ id = "agent_images", group = "agent", kind = "switch", default = true, label = "把图片发给 AI", hint = "触发消息里的图片，最多 3 张" },

	{ id = "thinking", group = "environment", kind = "choice", default = "default", choices = { "default", "off", "low", "medium", "high" }, label = "思考强度" },
	{ id = "model_analysis", group = "environment", kind = "text", default = "", label = "初判模型", hint = "如 opus 或 @smol；留空用默认模型" },
	{ id = "model_chat", group = "environment", kind = "text", default = "", label = "对话模型", hint = "/ 对话用；留空用默认模型" },
	{ id = "model_relevance", group = "environment", kind = "text", default = "", label = "关联判断模型", hint = "开始任务前判断强弱关联；简单二选一，可填 @smol" },
	{ id = "workspace", group = "environment", kind = "text", default = "", label = "Workspace 目录", hint = "AI 分析和任务的启动目录，支持绝对路径或 ~/；留空或不存在时用插件数据目录" },
	{ id = "skills_dir", group = "environment", kind = "text", default = "", label = "Skills 目录", hint = "额外技能目录，相对 Workspace；留空用默认发现规则" },

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
} :: { Field })

local BY_ID: { [string]: Field } = {}
for _, field in schema.FIELDS do
	BY_ID[field.id] = field
end

function schema.field(id: string): Field
	local field = BY_ID[id]
	assert(field, "未知设置项：" .. id)
	return field
end

function schema.known(id: any): boolean
	return type(id) == "string" and BY_ID[id] ~= nil
end

-- The value to use for a stored one: a value from another version, or one a
-- choice no longer offers, falls back to the default.
function schema.coerce(id: string, value: any): any
	local field = schema.field(id)
	if value == nil or type(value) ~= type(field.default) or (field.choices and not table.find(field.choices :: { any }, value)) then
		return field.default
	end
	return value
end

-- The next value of a switch or choice; a text field keeps its value.
function schema.step(id: string, value: any, direction: number): any
	local field = schema.field(id)
	if field.kind == "switch" then
		return not value
	elseif field.kind == "choice" then
		local choices = field.choices :: { any }
		local at = table.find(choices, value) or 1
		return choices[(at - 1 + direction) % #choices + 1]
	end
	return value
end

-- Field ids in page order: by group, then as listed.
function schema.order(): { string }
	local ids = {}
	for _, group in schema.GROUPS do
		for _, field in schema.FIELDS do
			if field.group == group.id then
				table.insert(ids, field.id)
			end
		end
	end
	return ids
end

return schema

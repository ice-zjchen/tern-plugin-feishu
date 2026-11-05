-- Pure workbench rendering. Layout hooks live in inbox.css and use Tern's theme.

local tern = require("tern")
local feishu = require("./feishu")
local settings = require("./settings")
local ui = tern.ui

local view = {}

view.DRAFT_ID = "main.body.right.reply.draft"
view.COMMAND_ID = "main.body.right.correction.field"
view.QUEUE_PREFIX = "main.body.middle.queue.items."

view.STATUS = {
	queued = { "待分析", "muted" },
	manual = { "不交给 agent", "muted" },
	running = { "分析中", "info" },
	failed = { "分析失败", "warning" },
	deep = { "要深入", "warning strong" },
	reply = { "要回复", "info strong" },
	fyi = { "可忽略", "muted" },
	snoozed = { "稍后", "muted" },
	handoff = { "待你发送", "accent" },
	task_starting = { "omp 启动中", "info" },
	task_working = { "omp 执行中", "info" },
	task_waiting = { "omp 等你", "warning strong" },
	task_done = { "本轮结束 / 待确认", "accent" },
	task_closed = { "tab 已关闭", "warning" },
	sent = { "已发送", "muted" },
	archived = { "已归档", "muted" },
	replied = { "已回复", "muted" },
}

-- An analysis for a message omp hasn't judged: you are writing the reply yourself.
function view.blank_analysis(): any
	return { pri = "P2", state = "reply", manual = true, summary = "", why = "", draft = "", task = { title = "", prompt = "" } }
end

local function t(text: string, token: string?): any
	return ui.span(text, token)
end

local function line(spans: any, props: any?): any
	local node = ui.text(spans)
	if props then
		local p = node.p or {}
		for k, v in props do
			p[k] = v
		end
		node.p = p
	end
	return node
end


-- Display width: CJK and full-width characters take two cells.
local function width(text: string): number
	local n = 0
	for _, c in utf8.codes(text) do
		n += if c >= 0x1100 then 2 else 1
	end
	return n
end

local function clip(text: string, cells: number): string
	local flat = string.gsub(string.gsub(text, "%s+", " "), "^ ", "")
	if width(flat) <= cells then
		return flat
	end
	local out, n = {}, 0
	for _, c in utf8.codes(flat) do
		local w = if c >= 0x1100 then 2 else 1
		if n + w > cells - 1 then
			break
		end
		table.insert(out, utf8.char(c))
		n += w
	end
	return table.concat(out) .. "…"
end

local function nav(key: string, act: string, label: string, count: number, current: boolean): any
	return ui.button(label .. " " .. tostring(count), {
		key = key,
		role = if current then "fl.nav.current" else "fl.nav",
		variant = "quiet",
		on = current,
		actions = { click = act },
	})
end

local function nav_strip(state: any, facts: any): any
	local tabs = {}
	for _, def in facts.views do
		if def.id == "pending" or def.id == "doing" or def.id == "fyi" or def.id == "later" or def.id == "done" then
			table.insert(tabs, nav(def.id, "view=" .. def.id, def.label, def.count, state.page ~= "settings" and not state.person and state.view == def.id))
		end
	end
	return ui.node("row", { key = "tabs", role = "fl.tabs", gap = "none", wrap = true }, tabs)
end

local function source_strip(state: any): any
	local sources = {}
	for _, source in { { "all", "全部" }, { "mention", "@我" }, { "dm", "私聊" } } do
		table.insert(sources, ui.button(source[2], {
			key = source[1],
			role = if (state.source or "all") == source[1] then "fl.source.current" else "fl.source",
			variant = "quiet",
			on = (state.source or "all") == source[1],
			actions = { click = "source=" .. source[1] },
		}))
	end
	return ui.node("row", { key = "sources", role = "fl.sources", gap = "xs", wrap = true }, sources)
end

-- Which section of the pending queue a row belongs to.
local function section_of(item: any): string
	local status = view.status(item)
	return if status == "deep" then "要深入" elseif status == "reply" then "要回复" else "待判断"
end

local function queue_block(state: any, facts: any, list_cells: number): any
	local items = {}
	local section: string? = nil
	local counts: { [string]: number } = {}
	if facts.grouped then
		for _, item in facts.queue do
			local group = section_of(item)
			counts[group] = (counts[group] or 0) + 1
		end
	end
	for _, item in facts.queue do
		if facts.grouped and section_of(item) ~= section then
			section = section_of(item)
			local token = if section == "要深入" then "warning strong" elseif section == "要回复" then "info strong" else "muted strong"
			table.insert(items, ui.node("item", {
				key = "section_" .. tostring(section),
				role = "fl.queue.section",
				label = { t((section :: string) .. " · " .. tostring(counts[section :: string]), token) },
			}))
		end
		local status = view.STATUS[view.status(item)]
		local summary = if item.analysis and not item.analysis.manual and item.analysis.summary ~= "" then item.analysis.summary else feishu.clean(item.content)
		local label: { any } = { t(item.name, "strong"), t(" " .. clip(if item.chat_type == "p2p" then "私聊" else item.chat, math.max(6, list_cells - width(item.name) - 10)), "muted") }
		if view.unread(item) then
			table.insert(label, t(" ●", "accent"))
		elseif item.is_read == nil and not view.settled(item) then
			table.insert(label, t(" ?", "muted"))
		end
		table.insert(label, "\n" .. clip(summary, list_cells) .. "\n")
		table.insert(label, t((if item.analysis then item.analysis.pri .. "  " else "") .. status[1], status[2]))
		if item.via and item.via ~= "" then
			table.insert(label, t("  " .. item.via, "muted"))
		end
		table.insert(items, ui.node("item", {
			key = item.id,
			role = "fl.queue.message",
			label = label,
			value = { t(string.sub(item.time, -5), "muted") },
		}))
	end
	return ui.node("col", { key = "queue", role = "fl.queue.panel", grow = 1, gap = "none" }, {
		ui.node("list", {
			key = "items",
			role = "fl.queue",
			selected = if state.selected then view.QUEUE_PREFIX .. state.selected else nil,
			empty = { t(if state.loading then "正在检索飞书消息…" else "这里没有消息了。", "muted") },
			max = 1,
			grow = 1,
		}, items),
	})
end

-- A message's pictures; click one to zoom. Nothing while images are off.
local function images_of(state: any, message: any): any
	local nodes = {}
	if settings.get("show_images") and not message.deleted then
		for _, key in feishu.images_in(tostring(message.content), 4) do
			local image = state.images[key]
			if image and image.blob then
				table.insert(nodes, ui.node("image", { key = key, blob = image.blob, role = "fl.image", alt = "消息图片", max = { h = "14lines" } }))
			elseif image and image.failed then
				table.insert(nodes, line({ t("[图片加载失败]", "muted") }, { key = key }))
			else
				table.insert(nodes, line({ t(if image then "[图片加载中…]" else "[图片未加载，重新选择消息或刷新]", "muted") }, { key = key }))
			end
		end
	end
	return ui.node("col", { key = "images", gap = "xs" }, nodes)
end

local function thread_block(state: any, item: any): any
	local messages = {
		ui.node("row", { key = "head", role = "fl.context.head", justify = "between", gap = "sm", wrap = true }, {
			line({ t("原消息", "muted strong") }),
			ui.button("在飞书打开", { key = "open", size = "sm", variant = "quiet", actions = { click = "open" } }),
		}),
		line({ t(item.chat, "muted") }, { role = "fl.context.meta" }),
	}
	local thread = item.thread or { { sender = item.name, time = item.time, content = item.content, id = item.id } }
	for i, message in thread do
		local hit = message.id == item.id
		table.insert(messages, ui.node("col", { key = "msg_" .. tostring(i), role = if hit then "fl.msg.hit" else "fl.msg", gap = "xs" }, {
			ui.node("row", { justify = "between", gap = "sm", wrap = true }, {
				line({ t(message.sender, "strong") }),
				line({ t(tostring(message.time), "muted") }),
			}),
			line(if message.deleted then { t("[消息已撤回]", "muted") } else feishu.clean(tostring(message.content))),
			images_of(state, message),
		}))
	end
	if item.thread_error then
		table.insert(messages, line({ t("未能读取会话上下文：" .. item.thread_error, "muted") }))
	end
	return ui.node("col", { key = "thread", role = "fl.context.thread", gap = "sm" }, messages)
end

local function analysis_block(state: any, item: any): any
	local a = item.analysis
	local status = view.status(item)
	local verdict = view.STATUS[status]
	local meta: { any } = { t(verdict[1], verdict[2]) }
	if a then
		table.insert(meta, "  " .. a.pri)
	end
	local sender_label = if item.sender_type == "bot" then "机器人" elseif item.sender_type == "user" then "用户" else "身份未知"
	table.insert(meta, t("  " .. sender_label, "muted"))
	table.insert(meta, t("  " .. item.name .. " · " .. (if item.chat_type == "p2p" then "私聊" else item.chat) .. " · " .. item.time, "muted"))
	local title = if a and not a.manual and a.summary ~= "" then a.summary else feishu.clean(item.content)
	local children: { any } = {
		line(meta, { key = "meta", role = "fl.summary.meta" }),
		line({ t(title, "strong") }, { key = "title", role = "fl.summary.title" }),
	}
	if a and a.manual then
		table.insert(children, line({ t("这条由你处理，omp 没有判断过。按 g 交给 omp。", "muted") }))
	elseif a and a.why ~= "" then
		table.insert(children, line({ t(a.why, "muted") }, { key = "why", role = "fl.summary.why" }))
	elseif status == "failed" then
		table.insert(children, line({ t("分析失败：" .. tostring(item.agent_error), "warning") }))
		table.insert(children, ui.node("row", { key = "retry" }, {
			ui.button("重试分析", { actions = { click = "retry" } }),
		}))
	elseif status == "running" then
		table.insert(children, line({ t("正在判断这条消息…", "info") }))
	elseif not a then
		local why = if status == "manual" then "按设置，这条不交给 agent。按 g 分析，或按 e 手写回复。"
			elseif not settings.get("agent_enabled") then "自动分析已关闭。按 g 分析，或按 e 手写回复。"
			elseif item.triage then "已保留处理状态；当前没有这条消息的分析。"
			else "这条消息还没有分析，选中后会排队。"
		table.insert(children, line({ t(why, "muted") }))
	end
	return ui.node("col", { key = "analysis", role = "fl.summary", gap = "sm" }, children)
end

local function next_block(state: any, item: any, facts: any): any
	local status = view.status(item)
	local locked = view.locked(item)
	local doing = item.triage == "doing"
	local kind = item.analysis and item.analysis.state
	local title = if doing then "omp 任务" elseif kind == "deep" then "给 omp 的任务" elseif kind == "reply" then "回复稿" else "下一步"
	local children: { any } = {
		ui.node("row", { key = "head", gap = "sm", wrap = true }, {
			line({ t(title, "strong") }),
			line({ t(if doing then "在新 tab 中处理" elseif kind == "deep" then "确认后在新 tab 运行，可以先改" elseif kind == "reply" then "复制后在飞书发送，可以先改" else "", "muted") }),
		}),
	}
	if doing then
		local says = if status == "task_waiting" then "omp 正在等你确认，按 a 跳过去。"
			elseif status == "task_done" then "本轮已结束，不代表任务已成功完成。请检查结果，确认完成后再归档。"
			elseif status == "task_closed" then "tab 已关闭，任务可能没做完。按 a 重新开 omp。"
			else "omp 正在新 tab 里处理。按 a 跳过去。"
		table.insert(children, line({ t(says, "muted") }))
	elseif kind == "deep" or kind == "reply" then
		-- Keep this direct child: inbox callbacks focus main.body.right.reply.draft.
		table.insert(children, ui.node("editor", {
			key = "draft", role = "fl.draft", text = facts.draft, cursor = state.draft_cursor,
			readonly = locked or state.mode ~= "draft", maxLines = 7,
			placeholder = if kind == "deep" then "任务说明" else "回复内容",
		}))
		if kind == "deep" and string.find(facts.reply_draft, "%S") then
			table.insert(children, ui.node("row", { key = "quick-reply", role = "fl.quick.reply", gap = "sm", wrap = true }, {
				line({ t("可以先回对方：", "muted"), facts.reply_draft }),
				ui.button("复制", { key = "copy", size = "sm", keys = { "c" }, actions = { click = "copy" } }),
			}))
		end
	else
		local why = if status == "running" or status == "queued" then "判断完成后，这里会出现下一步。"
			elseif status == "failed" then "可以重试分析，或按 e 手写回复。"
			elseif status == "manual" then "按 e 手写回复。"
			elseif kind == "fyi" then "这条不用处理。需要回复时按 e 手写。"
			else view.STATUS[status][1]
		table.insert(children, line({ t(why, "muted") }))
	end
	if item.spoken then
		table.insert(children, line({
			t(if item.triage == "handoff" then "可能已回复，待你确认：" else "已记录的回复：", "muted"),
			item.spoken,
		}, { key = "spoken", role = "fl.spoken" }))
		if item.triage == "handoff" then
			table.insert(children, ui.node("row", { key = "confirm" }, {
				ui.button("确认这是我的回复", { key = "reply", actions = { click = "confirm-reply" } }),
			}))
		end
	end
	local action = view.next_action(item)
	local buttons: { any } = {
		ui.button(action.label, { key = "primary", variant = "primary", keys = { "a" }, actions = { click = "primary" }, disabled = action.key == "none" }),
		ui.button("修改", { key = "edit", keys = { "e" }, actions = { click = "edit" }, disabled = locked or doing or status == "running" }),
		ui.button("稍后", { key = "snooze", keys = { "s" }, actions = { click = "snooze" }, disabled = locked }),
		ui.button(if status == "task_done" then "确认完成并归档" else "归档", { key = "archive", keys = { "x" }, actions = { click = "archive" }, disabled = locked }),
		ui.button("在飞书打开", { key = "open", keys = { "⏎" }, actions = { click = "open" } }),
		ui.button("直接开 omp", { key = "omp", title = "不管判断如何，直接开 omp 处理这条消息", keys = { "o" }, actions = { click = "omp" } }),
	}
	table.insert(children, ui.node("row", { key = "actions", role = "fl.actions", gap = "sm", wrap = true }, buttons))
	return ui.node("col", { key = "reply", role = if kind == "deep" then "fl.task.deep" else "fl.task", gap = "md" }, children)
end

local function correction(state: any): any
	return ui.node("col", { key = "correction", role = "fl.correction", gap = "sm" }, {
		line({ t("判断不对？直接告诉 omp  /", "muted") }),
		ui.node("input", {
			key = "field", role = "fl.command", text = state.command, cursor = state.command_cursor,
			readonly = state.mode ~= "command",
			placeholder = "不用深入，回一句就行；或补充任务要求",
		}),
		ui.node("row", { key = "actions", justify = "end", hidden = state.mode ~= "command" and state.command == "" }, {
			ui.button("发送", { key = "run", size = "sm", actions = { click = "run-command" }, busy = state.talking ~= nil }),
		}),
	})
end

local function conversation(state: any, item: any): any
	local children = {}
	if item.result and string.find(item.result, "%S") then
		table.insert(children, line({ t("omp 本轮结果 · 请核对", "muted strong") }))
		table.insert(children, line(item.result, { role = "fl.talk" }))
	end
	for _, entry in item.talk or {} do
		table.insert(children, line({
			t(if entry.me then "你  " else "omp  ", if entry.me then "accent" else "info"), entry.text,
		}, { role = "fl.talk" }))
	end
	if state.talking == item.id then
		table.insert(children, line({ t("omp 正在回答…", "info") }))
	end
	return ui.node("col", { key = "conversation", role = "fl.conversation", gap = "sm" }, children)
end

local function right(state: any, facts: any, wide: boolean): any
	local item = facts.item
	local children = {}
	if item then
		table.insert(children, analysis_block(state, item))
		table.insert(children, next_block(state, item, facts))
		table.insert(children, correction(state))
		table.insert(children, conversation(state, item))
		if not wide then
			table.insert(children, thread_block(state, item))
		end
	else
		table.insert(children, line({ t("选择队列里的一条消息，查看判断和下一步。", "muted") }, { role = "fl.empty" }))
	end
	return ui.node("col", { key = "right", role = "fl.detail", gap = "lg" }, children)
end

local function header(state: any, facts: any): any
	local status = if facts.running > 0 then "● 分析中 " .. tostring(facts.running)
		elseif not settings.get("agent_enabled") then "自动分析已暂停" else "分析空闲"
	local lines: { any } = {
		ui.node("row", { key = "bar", role = "fl.bar", justify = "between", gap = "md", wrap = true }, {
			nav_strip(state, facts),
			ui.node("row", { key = "actions", role = "fl.header.actions", gap = "sm", wrap = true }, {
				line({ t(status, if facts.running > 0 then "info" else "muted") }),
				ui.button(if state.loading then "刷新中…" else "刷新", {
					key = "refresh", size = "sm", actions = { click = "refresh" }, busy = state.loading, disabled = state.loading,
				}),
				ui.button(if state.page == "settings" then "返回工作台" else "设置", {
					key = "settings", size = "sm", keys = { "," }, actions = { click = "settings" },
				}),
			}),
		}),
	}
	if state.runtime_warning then
		table.insert(lines, line({ t(state.runtime_warning, "warning") }, { key = "runtime-warning", role = "fl.notice" }))
	end
	if state.problem then
		table.insert(lines, line({ t("检索失败 ", "warning strong"), state.problem }, { key = "problem", role = "fl.notice" }))
	elseif state.truncated then
		table.insert(lines, line({ t("部分来源超过 50 条，只显示了其中一页。", "muted") }, { key = "problem", role = "fl.notice" }))
	end
	return ui.node("col", { key = "head", gap = "none" }, lines)
end

local KEYS = { "j/k 上下", "a 下一步", "e 修改", "/ 改判", "o omp", "6 @我", "7 私聊" }
local SETTINGS_KEYS = { "j/k 上下", "空格 切换", "←/→ 换值", "Esc 返回" }

local function dock(state: any, narrow: boolean): any
	local hints = {}
	for _, hint in (if state.page == "settings" then SETTINGS_KEYS elseif narrow then { "j/k 上下", "a 下一步", "/ 改判" } else KEYS) do
		local k, label = string.match(hint, "^(%S+) (.+)$")
		table.insert(hints, t(k :: string, "strong"))
		table.insert(hints, t(" " .. (label :: string) .. "   ", "muted"))
	end
	local activity: { any } = {}
	local latest = state.log[1]
	if state.flash then
		table.insert(activity, line(state.flash, { key = "flash", role = "fl.activity" }))
	elseif latest then
		table.insert(activity, line({ t(latest.t .. " ", "muted"), latest.text }, { key = "latest", role = "fl.activity" }))
	end
	if state.undo then
		table.insert(activity, ui.button("撤销", { key = "undo", size = "sm", variant = "quiet", keys = { "u" }, actions = { click = "undo" } }))
	end
	return ui.node("row", { role = "fl.dock", justify = "between", gap = "sm", wrap = true }, {
		ui.node("row", { key = "activity", role = "fl.activity.row", gap = "sm" }, activity),
		line(hints, { key = "shortcuts", role = "fl.shortcuts" }),
	})
end

-- One settings row: the control the field's kind calls for.
local function field_row(state: any, field: any): any
	local value = settings.get(field.id)
	local current = state.settings_cursor == field.id
	local control
	if field.kind == "switch" then
		control = ui.node("switch", { key = "c", label = field.label, hint = field.hint, on = value })
	elseif field.kind == "choice" then
		local buttons = {}
		for i, choice in field.choices do
			local label = if choice == "default" then "默认" else tostring(choice)
			table.insert(buttons, ui.button(label, { key = tostring(i), size = "sm", on = choice == value, actions = { click = "set=" .. field.id .. ":" .. tostring(i) } }))
		end
		control = ui.node("row", { key = "c", justify = "between", gap = "md", wrap = true }, {
			line(field.label),
			ui.node("row", { key = "values", gap = "xs" }, buttons),
		})
	else
		local editing = state.mode == "setting" and current
		control = ui.node("col", { key = "wrap", gap = "xs" }, {
			line(field.label),
			ui.node("input", {
				key = "c",
				text = value,
				cursor = if editing then state.field_cursor else nil,
				readonly = not editing,
				placeholder = "回车编辑",
			}),
			line({ t(field.hint or "", "muted") }),
		})
	end
	return ui.node("col", { key = "f_" .. field.id, role = if current then "fl.field.current" else "fl.field" }, { control })
end

-- A framed group that takes the height of its rows: the page scrolls, not the group.
local function settings_group(key: string, number: string, title: string, meta: string?, rows: { any }): any
	local frame: { any } = {
		ui.node("text", { key = "title", role = "fl.title", spans = { t(number, "accent strong"), " " .. title } }),
	}
	if meta then
		table.insert(frame, ui.node("text", { key = "meta", role = "fl.meta", spans = { t(meta, "muted") } }))
	end
	table.insert(frame, ui.node("col", { key = "body", role = "fl.group.body", gap = "none" }, rows))
	return ui.node("col", { key = key, role = "fl.group", gap = "none" }, frame)
end

local function rules_block(state: any): any
	local rows = {}
	local rules = settings.rules()
	local ids = {}
	for id in rules do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		return tostring(rules[a].name) < tostring(rules[b].name)
	end)
	for _, id in ids do
		local rule = rules[id]
		table.insert(rows, ui.node("row", { key = id, justify = "between", gap = "md", role = "fl.field" }, {
			line({ tostring(rule.name), t(if rule.mode == "hide" then "  不显示" else "  不交给 agent", "muted") }),
			ui.node("row", { key = "actions", gap = "xs" }, {
				ui.button(if rule.mode == "hide" then "改为不分析" else "改为不显示", { key = "mode", size = "sm", actions = { click = "rule-mode=" .. id } }),
				ui.button("移除", { key = "del", size = "sm", actions = { click = "rule-del=" .. id } }),
			}),
		}))
	end
	if #rows == 0 then
		table.insert(rows, line({ t("在队列里按 i 不显示某个会话，按 n 让它显示但不交给 agent。", "muted") }))
	end
	return settings_group("rules", "6", "会话规则", tostring(#ids) .. " 条", rows)
end

function view.settings_body(state: any): any
	local columns: { [string]: { any } } = { left = {}, right = {} }
	for _, group in settings.GROUPS do
		local rows = {}
		for _, field in settings.FIELDS do
			if field.group == group.id then
				table.insert(rows, field_row(state, field))
			end
		end
		table.insert(columns[group.column], settings_group(group.id, group.number, group.title, nil, rows))
	end
	table.insert(columns.right, rules_block(state))
	return ui.node("row", { key = "settings", role = "fl.settings", wrap = true, align = "start" }, {
		ui.node("col", { key = "left", role = "fl.settings.column", gap = "none" }, columns.left),
		ui.node("col", { key = "right", role = "fl.settings.column", gap = "none" }, columns.right),
	})
end

-- The id of a settings field's control, for focus.
function view.field_control_id(id: string): string
	local field = settings.field(id)
	local column = "left"
	for _, group in settings.GROUPS do
		if group.id == field.group then
			column = group.column
		end
	end
	return "main.settings." .. column .. "." .. field.group .. ".body.f_" .. id .. ".wrap.c"
end

-- Whether a message is settled: nothing about it can change any more.
function view.locked(item: any): boolean
	local status = view.status(item)
	return status == "sent" or status == "archived" or status == "replied"
end

-- Whether a message is finished with. Its read state is no longer kept current.
function view.settled(item: any): boolean
	return item.triage == "sent" or item.triage == "archived" or item.triage == "replied"
end

function view.unread(item: any): boolean
	return item.is_read == false and not view.settled(item)
end

-- What a queue row shows as its state.
function view.status(item: any): string
	if item.triage == "doing" then
		return "task_" .. tostring(item.task_state or "working")
	end
	if item.triage then
		return item.triage
	end
	if item.agent == "queued" and item.no_agent then
		return "manual"
	end
	if item.agent == "done" then
		return if item.analysis then item.analysis.state else "reply"
	end
	return item.agent
end

-- What `a` does for a message, and what its button says. One key for all of it:
-- the label is how you know which it is.
function view.next_action(item: any): { key: string, label: string }
	local status = view.status(item)
	if status == "task_done" then
		return { key = "archive", label = "确认完成并归档" }
	elseif status == "task_closed" then
		return { key = "reopen", label = "重新开 omp" }
	elseif item.triage == "doing" then
		return { key = "jump", label = "跳到 omp" }
	elseif status == "handoff" then
		return { key = "copy", label = "再次复制并去飞书" }
	elseif view.locked(item) or not item.analysis then
		return { key = "none", label = if view.locked(item) then view.STATUS[status][1] else "等待判断" }
	end
	local kind = item.analysis.state
	if kind == "deep" then
		return { key = "task", label = "开 omp 去处理" }
	elseif kind == "fyi" then
		return { key = "archive", label = "归档" }
	end
	local draft = item.edited or item.analysis.draft
	return { key = "copy", label = if string.find(draft, "%S") then "复制并去回复" else "去飞书回复" }
end

function view.render(state: any, facts: any, cx: any): any
	if state.page == "settings" then
		return {
			main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts), view.settings_body(state) }),
			dock = dock(state, cx.cols < 96),
		}
	end
	local wide = cx.cols >= 150
	local medium = cx.cols >= 96
	local list_cells = math.max(12, if medium then math.min(42, math.floor(cx.cols * 0.25) - 7) else cx.cols - 14)
	local middle = ui.node("col", { key = "middle", role = "fl.sidebar", gap = "none" }, {
		source_strip(state),
		queue_block(state, facts, list_cells),
	})
	local parts: { any } = { middle, right(state, facts, wide) }
	if wide and facts.item then
		table.insert(parts, ui.node("col", { key = "context", role = "fl.context", gap = "none" }, {
			thread_block(state, facts.item),
		}))
	end
	local body = ui.node(if medium then "row" else "col", {
		key = "body", role = if medium then "fl.layout" else "fl.layout.stack", gap = "none", align = "stretch",
	}, parts)
	return {
		main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts), body }),
		dock = dock(state, not medium),
	}
end

return view

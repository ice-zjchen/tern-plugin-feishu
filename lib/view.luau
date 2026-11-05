-- Pure workbench rendering. Layout hooks live in inbox.css and use Tern's theme.

local tern = require("tern")
local feishu = require("./feishu")
local settings = require("./settings")
local ui = tern.ui

local view = {}

view.DRAFT_ID = "main.body.right.reply.draft"
view.COMMAND_ID = "main.body.right.reply.correction.input.field"
view.QUEUE_PREFIX = "main.body.middle.queue.items."

view.STATUS = {
	queued = { "待分析", "muted" },
	manual = { "不交给 agent", "muted" },
	running = { "分析中", "info" },
	failed = { "分析失败", "warning" },
	deep = { "待交办", "muted" },
	reply = { "待回复", "muted" },
	fyi = { "可忽略", "muted" },
	snoozed = { "稍后", "muted" },
	handoff = { "待你发送", "accent" },
	task_starting = { "omp 启动中", "muted" },
	task_working = { "omp 执行中", "muted" },
	task_waiting = { "omp 等你", "warning" },
	task_done = { "本轮结束 / 待确认", "warning" },
	task_closed = { "tab 已关闭", "warning" },
	sent = { "已发送", "muted" },
	archived = { "已归档", "muted" },
	replied = { "已回复", "muted" },
}

-- An analysis for a message omp hasn't judged: you are writing the reply yourself.
function view.blank_analysis(): any
	return { pri = "P2", state = "reply", manual = true, summary = "", why = "", draft = "", task = { title = "", prompt = "" } }
end

-- How many messages the side column shows before the rest move to the modal.
local INLINE_MESSAGES = 4

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
		if def.id == "pending" or def.id == "doing" or def.id == "later" or def.id == "done" then
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


local function queue_foot(state: any, facts: any): any?
	local count = 0
	for _, def in facts.views do
		if def.id == "fyi" then
			count = def.count
		end
	end
	if state.view == "fyi" and not state.person then
		return ui.node("row", { key = "quiet", role = "fl.queue.foot", justify = "between", gap = "sm" }, {
			line({ t("正在看可忽略的消息", "muted") }),
			ui.button("返回", { key = "back", size = "sm", variant = "quiet", actions = { click = "view=pending" } }),
		})
	elseif count == 0 then
		return nil
	end
	return ui.node("row", { key = "quiet", role = "fl.queue.foot", justify = "between", gap = "sm" }, {
		line({ t("可忽略 " .. tostring(count) .. " 条", "muted") }),
		ui.button("查看", { key = "show", size = "sm", variant = "quiet", actions = { click = "view=fyi" } }),
	})
end

local function queue_block(state: any, facts: any, list_cells: number): any
	local items = {}
	for _, item in facts.queue do
		local status = view.STATUS[view.status(item)]
		local summary = if item.analysis and not item.analysis.manual and item.analysis.summary ~= "" then item.analysis.summary else feishu.clean(item.content)
		local where = if item.chat_type == "p2p" then "私聊" else item.chat
		local label: { any } = {
			clip(summary, math.max(6, list_cells - 6)) .. "\n",
			t(clip(item.name .. " · " .. where, math.max(6, list_cells - width(status[1]) - 4)), "muted"),
		}
		if view.unread(item) then
			table.insert(label, t(" ●", "accent"))
		elseif item.is_read == nil and not view.settled(item) then
			table.insert(label, t(" ?", "muted"))
		end
		table.insert(items, ui.node("item", {
			key = item.id,
			role = "fl.queue.message",
			label = label,
			value = { t(string.sub(item.time, -5), "muted"), "\n", t(status[1], status[2]) },
		}))
	end
	local children: { any } = {
		ui.node("list", {
			key = "items",
			role = "fl.queue",
			selected = if state.selected then view.QUEUE_PREFIX .. state.selected else nil,
			empty = { t(if state.loading then "正在检索飞书消息…" else "这里没有消息了。", "muted") },
			max = 1,
			grow = 1,
		}, items),
	}
	local foot = queue_foot(state, facts)
	if foot then
		table.insert(children, foot)
	end
	return ui.node("col", { key = "queue", role = "fl.queue.panel", grow = 1, gap = "none" }, children)
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

local function thread_of(item: any): { any }
	return item.thread or { { sender = item.name, time = item.time, content = item.content, id = item.id } }
end

local function message_node(state: any, key: string, message: any, hit: boolean): any
	return ui.node("col", { key = key, role = if hit then "fl.msg.hit" else "fl.msg", gap = "xs" }, {
		ui.node("row", { justify = "between", gap = "sm", wrap = true }, {
			line({ t(message.sender, "strong") }),
			line({ t(string.sub(tostring(message.time), -5), "muted") }),
		}),
		line(if message.deleted then { t("[消息已撤回]", "muted") } else feishu.clean(tostring(message.content)), { role = "fl.msg.text" }),
		images_of(state, message),
	})
end

-- The most recent messages, always including the one that put this item in the queue.
local function thread_window(thread: { any }, item: any): (number, number)
	local total, hit = #thread, #thread
	for i, message in thread do
		if message.id == item.id then
			hit = i
		end
	end
	local first = math.max(1, total - INLINE_MESSAGES + 1)
	if hit < first then
		return hit, math.min(total, hit + INLINE_MESSAGES - 1)
	end
	return first, total
end

local function thread_scope(item: any): string
	return (if item.chat_type == "p2p" then "私聊" else item.chat) .. " · 触发消息及其上下文"
end

-- The conversation itself, readable beside the plan. Only a long one needs the modal.
local function thread_block(state: any, item: any): any
	local thread = thread_of(item)
	local first, last = thread_window(thread, item)
	local actions: { any } = {}
	if last - first + 1 < #thread then
		table.insert(actions, ui.button("全部 " .. tostring(#thread) .. " 条", { key = "all", size = "sm", variant = "quiet", actions = { click = "open-thread" } }))
	end
	table.insert(actions, ui.button("在飞书打开", { key = "open", size = "sm", variant = "quiet", actions = { click = "open" } }))
	local messages: { any } = {
		ui.node("row", { key = "head", role = "fl.context.head", justify = "between", gap = "sm", wrap = true }, {
			line({ t("原始对话", "strong") }),
			ui.node("row", { key = "actions", gap = "xs" }, actions),
		}),
		line({ t(thread_scope(item), "muted") }, { role = "fl.context.meta" }),
	}
	for i = first, last do
		table.insert(messages, message_node(state, "msg_" .. tostring(i), thread[i], thread[i].id == item.id))
	end
	if item.thread_error then
		table.insert(messages, line({ t("未能读取会话上下文：" .. item.thread_error, "muted") }))
	end
	return ui.node("col", { key = "thread", role = "fl.context.thread", gap = "sm" }, messages)
end

-- Without the side column, what was asked stays on screen: never hand off blind.
local function quote_block(state: any, item: any): any
	local children: { any } = {
		line(if item.deleted then { t("[消息已撤回]", "muted") } else feishu.clean(tostring(item.content)), { key = "text", role = "fl.msg.text" }),
		images_of(state, item),
	}
	local actions: { any } = {}
	local count = #thread_of(item)
	if count > 1 then
		table.insert(actions, ui.button("查看全部 " .. tostring(count) .. " 条对话", { key = "all", size = "sm", variant = "quiet", actions = { click = "open-thread" } }))
	end
	table.insert(actions, ui.button("在飞书打开", { key = "open", size = "sm", variant = "quiet", actions = { click = "open" } }))
	table.insert(children, ui.node("row", { key = "actions", gap = "xs", wrap = true }, actions))
	return ui.node("col", { key = "quote", role = "fl.quote", gap = "xs" }, children)
end

local function thread_dialog(state: any, item: any): any
	local children: { any } = {
		ui.button("关闭", { key = "close", variant = "quiet", keys = { "esc" }, actions = { click = "close-thread" } }),
		line({ t(thread_scope(item) .. " · " .. tostring(#thread_of(item)) .. " 条", "muted") }, { key = "scope" }),
	}
	for i, message in thread_of(item) do
		table.insert(children, message_node(state, "msg_" .. tostring(i), message, message.id == item.id))
	end
	return ui.col({ ui.node("overlay", {
		key = "thread", head = "原始对话", meta = { t(item.name .. " · " .. item.chat, "muted") }, size = "lg", modal = true,
		["end"] = "layer.thread.close",
	}, children) })
end

local function folded(key: string, title: string, children: { any }): any
	local node = ui.section(title, children)
	node.p = node.p or {}
	node.p.key = key
	node.p.collapsed = true
	node.p.collapsible = true
	return node
end

local function why_of(item: any): string?
	local a = item.analysis
	return if a and not a.manual and a.why ~= "" then a.why else nil
end

local function analysis_block(state: any, item: any): any
	local a = item.analysis
	local status = view.status(item)
	local where = if item.chat_type == "p2p" then "私聊" else item.chat
	local byline = (if a and not a.manual then a.pri .. " · " else "") .. item.name .. " · " .. where .. " · " .. string.sub(item.time, -5)
	if item.sender_type ~= "user" then
		byline ..= " · " .. (if item.sender_type == "bot" then "机器人" else "身份未知")
	end
	if item.via and item.via ~= "" then
		byline ..= " · " .. item.via
	end
	local tools: { any } = {}
	if status ~= "task_starting" and status ~= "task_working" and not view.locked(item) then
		table.insert(tools, ui.button(if status == "snoozed" then "移回需要我" else "稍后", { key = "snooze", size = "sm", variant = "quiet", keys = { "s" }, actions = { click = "snooze" } }))
		if view.next_action(item).key ~= "archive" and status ~= "task_done" then
			table.insert(tools, ui.button("归档", { key = "archive", size = "sm", variant = "quiet", keys = { "x" }, actions = { click = "archive" } }))
		end
	end
	local title = if a and not a.manual and a.summary ~= "" then a.summary else feishu.clean(item.content)
	local children: { any } = {
		line({ t(title, "strong") }, { key = "title", role = "fl.summary.title" }),
		ui.node("row", { key = "top", justify = "between", gap = "md", wrap = true }, {
			line({ t(byline, "muted") }, { key = "meta", role = "fl.summary.meta" }),
			ui.node("row", { key = "tools", gap = "xs" }, tools),
		}),
	}
	if a and a.manual then
		table.insert(children, line({ t("这条由你处理，omp 没有判断过。", "muted") }))
	elseif status == "failed" then
		table.insert(children, line({ t("分析失败：" .. tostring(item.agent_error), "warning") }))
		table.insert(children, ui.node("row", { key = "retry" }, {
			ui.button("重试分析", { actions = { click = "retry" } }),
		}))
	elseif status == "running" then
		table.insert(children, line({ t("正在判断这条消息…", "info") }))
	elseif not a and not item.triage then
		local why = if status == "manual" then "按设置，这条不交给 agent。"
			elseif not settings.get("agent_enabled") then "自动分析已关闭。"
			else "这条消息还没有分析，选中后会排队。"
		table.insert(children, line({ t(why, "muted") }))
	end
	return ui.node("col", { key = "analysis", role = "fl.summary", gap = "sm" }, children)
end

-- Talks to the analysis session, which can change the judgment, the draft and the task.
-- It cannot reach a running omp tab, so those states don't offer it.
local function correction(state: any, kind: string?): any
	local label = if kind == "deep" then "让 omp 改判断或任务说明，不会启动任务"
		elseif kind == "reply" then "让 omp 改这条回复或判断"
		else "让 omp 调整判断"
	local placeholder = if kind == "reply" then "例如：语气正式一点；或者这条要深入处理" else "例如：不用深入，回一句就行"
	return ui.node("col", { key = "correction", role = "fl.correction", gap = "sm" }, {
		line({ t(label, "muted") }),
		ui.node("row", { key = "input", role = "fl.correction.row", gap = "sm" }, {
			ui.node("input", {
				key = "field", role = "fl.command", text = state.command, cursor = state.command_cursor,
				readonly = state.mode ~= "command", placeholder = placeholder,
			}),
			ui.button("发送", { key = "run", variant = "quiet", actions = { click = "run-command" }, busy = state.talking ~= nil }),
		}),
	})
end

local function primary_button(item: any, variant: string): any
	local action = view.next_action(item)
	local props: any = { key = "primary", role = "fl.primary", variant = variant, actions = { click = "primary" }, disabled = action.key == "none" }
	if view.needs_confirm(item) then
		-- No shortcut on purpose: a stray `a` must not start this one.
		props.actions = { click = "confirm-task" }
		return ui.button("确认，交给 omp", props)
	end
	props.keys = { "a" }
	return ui.button(action.label, props)
end

local function task_card(state: any, item: any, facts: any): any
	local status = view.status(item)
	local children: { any } = {}
	local function head(title: string)
		table.insert(children, line({ t(title, "strong") }, { key = "head", role = "fl.task.title" }))
	end
	local function buttons(...)
		table.insert(children, ui.node("row", { key = "actions", role = "fl.actions", gap = "sm", wrap = true }, { ... }))
	end
	if status == "task_done" then
		head("omp 本轮结果 · 请核对")
		table.insert(children, line({ t("这是 omp 的原话。本轮结束不代表任务完成。", "muted") }))
		if item.result and string.find(item.result, "%S") then
			table.insert(children, line(item.result, { key = "result", role = "fl.result" }))
		else
			table.insert(children, line({ t("omp 没有留下文字结果，请到 tab 里查看。", "muted") }))
		end
		buttons(
			primary_button(item, "primary"),
			ui.button("确认完成并归档", { key = "archive", variant = "quiet", keys = { "x" }, actions = { click = "archive" } })
		)
	elseif status == "task_waiting" then
		head("omp 在等你")
		table.insert(children, line("它的问题在 omp tab 里，回答也在那里进行。"))
		buttons(primary_button(item, "primary"))
	elseif status == "task_closed" then
		head("omp tab 已关闭")
		table.insert(children, line("任务可能没做完。可以重新打开，或者确认后归档。"))
		buttons(primary_button(item, "primary"))
	else
		head(if status == "task_starting" then "omp 启动中" else "omp 正在处理")
		table.insert(children, line("不需要留在这里等待。omp 等你，或本轮结束时，这条会回到「需要我」。"))
		table.insert(children, line({ t("要补充要求，到 omp tab 里说。这里的内容到不了正在运行的任务。", "muted") }))
		buttons(primary_button(item, "quiet"))
	end
	if status ~= "task_done" and item.analysis and item.analysis.state == "deep" and string.find(facts.draft, "%S") then
		table.insert(children, folded("scope", "已交办的任务", { line(facts.draft, { role = "fl.plan" }) }))
	end
	return ui.node("col", { key = "reply", role = "fl.task", gap = "md" }, children)
end

local function next_block(state: any, item: any, facts: any): any
	if item.triage == "doing" then
		return task_card(state, item, facts)
	end
	local status = view.status(item)
	local locked = view.locked(item)
	local kind = item.analysis and item.analysis.state
	local editable = kind == "deep" or kind == "reply"
	local title = if locked then view.STATUS[status][1]
		elseif kind == "deep" then "交给 omp 处理"
		elseif kind == "reply" then (if status == "handoff" then "待你发送" else "回复给 " .. item.name)
		else "下一步"
	local children: { any } = { line({ t(title, "strong") }, { key = "head", role = "fl.task.title" }) }
	if editable and not locked then
		-- Keep this direct child: inbox callbacks focus main.body.right.reply.draft.
		table.insert(children, ui.node("editor", {
			key = "draft", role = "fl.draft", text = facts.draft, cursor = state.draft_cursor,
			readonly = state.mode ~= "draft", maxLines = 7,
			placeholder = if kind == "deep" then "任务说明" else "回复内容",
		}))
	elseif locked then
		if string.find(facts.draft, "%S") then
			table.insert(children, line(facts.draft, { key = "draft-text", role = "fl.plan" }))
		end
	else
		local why = if status == "running" or status == "queued" then "判断完成后，这里会出现下一步。"
			elseif status == "failed" then "可以重试分析，或者自己手写回复。"
			elseif kind == "fyi" then why_of(item) or "这条不用处理。"
			else "可以自己手写回复。"
		table.insert(children, line({ t(why, "muted") }))
	end
	if kind == "deep" and not locked and view.needs_confirm(item) then
		table.insert(children, ui.node("col", { key = "risk", role = "fl.risk", gap = "xs" }, {
			line({ t("对方要的动作：", "warning"), t(item.analysis.risk, "warning strong") }),
			line({ t("上面的要求只是任务说明，不是权限限制。omp 按项目配置运行，有权限时可能真的执行。", "muted") }),
		}))
	elseif kind == "deep" and not locked then
		table.insert(children, line({ t("确认后在新 tab 运行，开始前可以先改。", "muted") }))
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
	if not locked then
		local buttons: { any } = {}
		if view.next_action(item).key ~= "none" then
			table.insert(buttons, primary_button(item, "primary"))
		end
		if status ~= "running" then
			table.insert(buttons, ui.button(if kind == "deep" then "修改要求" elseif editable then "修改" else "手写回复", { key = "edit", variant = "quiet", keys = { "e" }, actions = { click = "edit" } }))
		end
		if not editable then
			if status == "manual" or (item.analysis and item.analysis.manual) then
				table.insert(buttons, ui.button("交给 omp 分析", { key = "force", variant = "quiet", keys = { "g" }, actions = { click = "force" } }))
			end
			table.insert(buttons, ui.button("直接开 omp", { key = "omp", variant = "quiet", keys = { "o" }, title = "不管判断如何，直接开 omp 处理这条消息", actions = { click = "omp" } }))
		end
		table.insert(children, ui.node("row", { key = "actions", role = "fl.actions", gap = "sm", wrap = true }, buttons))
	end
	if view.can_adjust(item) then
		table.insert(children, correction(state, kind))
	end
	return ui.node("col", { key = "reply", role = "fl.task", gap = "md" }, children)
end

local function conversation(state: any, item: any): any
	local children = {}
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
		if not wide then
			table.insert(children, quote_block(state, item))
		end
		table.insert(children, next_block(state, item, facts))
		local why = why_of(item)
		if not wide and why and item.analysis.state ~= "fyi" then
			table.insert(children, folded("why", "判断理由", { line(why, { role = "fl.context.text" }) }))
		end
		if item.analysis and item.analysis.state == "deep" and not item.triage and string.find(facts.reply_draft, "%S") then
			table.insert(children, folded("quick-reply", "先回一句", {
				line(facts.reply_draft, { role = "fl.quick.reply" }),
				ui.button("复制回复", { key = "copy", size = "sm", variant = "quiet", keys = { "c" }, actions = { click = "copy" } }),
			}))
		end
		table.insert(children, conversation(state, item))
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
					key = "settings", size = "sm", actions = { click = "settings" },
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

local KEYS = { "j/k 上下", "a 下一步", "o omp", "6 @我", "7 私聊" }
local ADJUST_KEYS = { "j/k 上下", "a 下一步", "e 修改", "/ 让 omp 调整", "o omp", "6 @我", "7 私聊" }
local SETTINGS_KEYS = { "j/k 上下", "空格 切换", "←/→ 换值", "Esc 返回" }

local function dock(state: any, facts: any, narrow: boolean): any
	local hints = {}
	local adjustable = facts.item ~= nil and view.can_adjust(facts.item)
	for _, hint in (if state.page == "settings" then SETTINGS_KEYS elseif narrow then { "j/k 上下", "a 下一步" } elseif adjustable then ADJUST_KEYS else KEYS) do
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

-- A running omp tab that needs you back: it asked something, finished or was closed.
function view.task_needs_me(item: any): boolean
	return item.triage == "doing" and (item.task_state == "waiting" or item.task_state == "done" or item.task_state == "closed")
end

-- A request with a hard-to-undo action only starts from the button, never from `a`.
function view.needs_confirm(item: any): boolean
	local a = item.analysis
	return not view.locked(item) and item.triage ~= "doing" and a ~= nil and a.state == "deep" and type(a.risk) == "string" and string.find(a.risk, "%S") ~= nil
end

-- The adjust box talks to the analysis session, which can't reach a task in a tab.
function view.can_adjust(item: any): boolean
	return not view.locked(item) and item.triage ~= "doing"
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
		return { key = "jump", label = "继续到 omp" }
	elseif status == "task_closed" then
		return { key = "reopen", label = "重新开 omp" }
	elseif status == "task_waiting" then
		return { key = "jump", label = "到 omp 回答" }
	elseif item.triage == "doing" then
		return { key = "jump", label = "跳到 omp" }
	elseif status == "handoff" then
		return { key = "copy", label = "再次复制并去飞书" }
	elseif view.locked(item) or not item.analysis then
		return { key = "none", label = if view.locked(item) then view.STATUS[status][1] else "等待判断" }
	end
	local kind = item.analysis.state
	if kind == "deep" then
		return { key = "task", label = "交给 omp" }
	elseif kind == "fyi" then
		return { key = "archive", label = "归档" }
	end
	local draft = item.edited or item.analysis.draft
	return { key = "copy", label = if string.find(draft, "%S") then "复制并去回复" else "去飞书回复" }
end

-- Three columns only when none has to be squeezed; below that the conversation folds away.
local WIDE_COLS = 170
local WIDE_MEDIUM = 110

function view.render(state: any, facts: any, cx: any): any
	if state.page == "settings" then
		return {
			main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts), view.settings_body(state) }),
			dock = dock(state, facts, cx.cols < WIDE_MEDIUM),
		}
	end
	local wide = cx.cols >= WIDE_COLS
	local medium = cx.cols >= WIDE_MEDIUM
	local list_cells = math.max(12, if medium then 44 else cx.cols - 14)
	local middle = ui.node("col", { key = "middle", role = "fl.sidebar", gap = "none" }, {
		source_strip(state),
		queue_block(state, facts, list_cells),
	})
	local parts: { any } = { middle, right(state, facts, wide) }
	if wide and facts.item then
		local side: { any } = { thread_block(state, facts.item) }
		local why = why_of(facts.item)
		if why then
			table.insert(side, ui.node("col", { key = "why", role = "fl.context.why", gap = "sm" }, {
				line({ t("判断理由", "strong") }),
				line(why, { role = "fl.context.text" }),
			}))
		end
		table.insert(parts, ui.node("col", { key = "context", role = "fl.context", gap = "lg" }, side))
	end
	local body = ui.node(if medium then "row" else "col", {
		key = "body", role = if medium then "fl.layout" else "fl.layout.stack", gap = "none", align = "stretch",
	}, parts)
	return {
		main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts), body }),
		dock = dock(state, facts, not medium),
		layer = if facts.dialog_item then thread_dialog(state, facts.dialog_item) else nil,
	}
end

return view

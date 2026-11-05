-- The workbench's blocks. Pure drawing: state goes in, nodes come out. Frames
-- live in inbox.css, its hooks are the `fl.*` roles; colors are the theme's.

local tern = require("tern")
local feishu = require("./feishu")
local settings = require("./settings")
local ui = tern.ui

local view = {}

view.DRAFT_ID = "main.body.right.reply.draft"
view.COMMAND_ID = "dock.cmd.field"
view.QUEUE_PREFIX = "main.body.middle.queue.items."

view.STATUS = {
	queued = { "待分析", "muted" },
	manual = { "不交给 agent", "muted" },
	running = { "分析中", "info" },
	failed = { "分析失败", "warning" },
	needs = { "待你决定", "warning strong" },
	ready = { "稿已备好", "info strong" },
	fyi = { "建议忽略", "muted" },
	snoozed = { "稍后", "muted" },
	sending = { "发送中", "accent" },
	sent = { "已发送", "muted" },
	archived = { "已归档", "muted" },
	replied = { "已在飞书回复", "muted" },
}

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

-- A framed block with its number and title sitting on the border. Its children
-- scroll inside the frame; `foot` stays visible below them.
local function block(key: string, number: string, title: string, meta: string?, children: { any }, props: any?, foot: any?): any
	local frame: { any } = {
		ui.node("text", { key = "title", role = "fl.title", spans = { t(number, "accent strong"), " " .. title } }),
	}
	if meta and meta ~= "" then
		table.insert(frame, ui.node("text", { key = "meta", role = "fl.meta", spans = { t(meta, "muted") } }))
	end
	local body: { [string]: any } = { key = "body", role = "fl.body", grow = 1 }
	table.insert(frame, ui.node("scroll", body, children))
	if foot then
		table.insert(frame, foot)
	end
	local p: { [string]: any } = { key = key, role = "fl.block", gap = "none" }
	for k, v in props or {} do
		p[k] = v
	end
	return ui.node("col", p, frame)
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
	return ui.node("row", {
		key = key, role = if current then "fl.nav.current" else "fl.nav", justify = "between", gap = "md", actions = { click = act },
	}, {
		line(label),
		line({ t(tostring(count), if current then nil else "muted") }),
	})
end

local function left(state: any, facts: any): any
	local views = {}
	for i, def in facts.views do
		table.insert(views, nav(def.id, "view=" .. def.id, tostring(i) .. " " .. def.label, def.count, not state.person and state.view == def.id))
	end
	local people = {}
	for _, person in facts.people do
		table.insert(people, nav(person.id, "person=" .. person.id, "★ " .. person.name, person.count, state.person == person.id))
	end
	if #people == 0 then
		table.insert(people, line({ t("在队列里按 * 星标发送者", "muted") }))
	end
	local cal = if state.agenda then { t("已读取", "info") }
		elseif not settings.get("use_agenda") then { t("已关闭", "muted") }
		else { t(if state.agenda_error then "未授权" else "读取中", "muted") }
	local cost = string.format("$%.2f", state.spent)
	return ui.node("col", { key = "left", role = "fl.column.left", gap = "lg" }, {
		block("views", "1", "视图", nil, views),
		block("people", "2", "星标联系人", nil, people),
		block("agent", "3", "omp", if settings.get("agent_enabled") then nil else "已暂停", {
			ui.kv({
				{ { t("分析中", "muted") }, tostring(facts.running) },
				{ { t("稿已备", "muted") }, tostring(facts.ready) },
				{ { t("可忽略", "muted") }, tostring(facts.fyi) },
				{ { t("花费", "muted") }, cost },
			}),
			line({ t("权限", "muted") }, { role = "fl.section" }),
			ui.kv({
				{ { t("读取", "muted") }, "消息" },
				{ { t("日历", "muted") }, cal },
				{ { t("发送", "muted") }, { t("需你确认", "accent") } },
				{ { t("归档", "muted") }, { t("仅本地", "accent") } },
			}),
		}, { grow = 1 }),
	})
end

-- The views as one line, where the left column doesn't fit.
local function nav_strip(state: any, facts: any): any
	local views = {}
	for i, def in facts.views do
		table.insert(views, nav(def.id, "view=" .. def.id, tostring(i) .. " " .. def.label, def.count, not state.person and state.view == def.id))
	end
	return ui.node("row", { key = "strip", role = "fl.strip", gap = "sm", wrap = true }, views)
end

local function queue_block(state: any, facts: any, list_cells: number): any
	local items = {}
	for _, item in facts.queue do
		local status = view.STATUS[view.status(item)]
		local summary = if item.analysis and not item.analysis.manual then item.analysis.summary else feishu.clean(item.content)
		local head: { any } = { t(item.name, "strong") }
		if item.chat_type ~= "p2p" then
			table.insert(head, t(" " .. clip(item.chat, math.max(6, list_cells - width(item.name) - 12)), "muted"))
		end
		local label: { any } = { t(if item.id == state.selected then "▸" else " ", "accent") }
		-- ● unread in Feishu, ? Feishu can't say, nothing once read.
		if view.unread(item) then
			table.insert(label, t("●", "accent"))
		elseif item.is_read == nil and not view.settled(item) then
			table.insert(label, t("?", "muted"))
		else
			table.insert(label, " ")
		end
		for _, span in head do
			table.insert(label, span)
		end
		table.insert(label, "\n  " .. clip(summary, list_cells - 2) .. "\n  ")
		local sender_label = if item.sender_type == "bot" then "机器人" elseif item.sender_type == "user" then "用户" else "身份未知"
		table.insert(label, t((if item.analysis then item.analysis.pri else "··") .. " · " .. item.via .. " · " .. sender_label, "muted"))
		table.insert(items, ui.node("item", {
			key = item.id,
			label = label,
			value = { t(string.sub(item.time, -5), "muted"), "\n\n", t(status[1], status[2]) },
		}))
	end
	-- Enable the list's own scroller and selected-row reveal. CSS bounds it to
	-- the queue's allocated space instead of estimating rows from pane height.
	local list = ui.node("list", {
		key = "items",
		role = "fl.queue",
		selected = if state.selected then view.QUEUE_PREFIX .. state.selected else nil,
		empty = { t(if state.loading then "$ 正在检索飞书消息…" else "$ 这里没有消息了。", "muted") },
		max = 1,
		grow = 1,
	}, items)
	return ui.node("col", { key = "queue", role = "fl.block", grow = 1, gap = "none" }, {
		ui.node("text", { key = "title", role = "fl.title", spans = { t("4", "accent strong"), " 队列" } }),
		ui.node("text", { key = "meta", role = "fl.meta", spans = { t(facts.queue_label .. " · " .. tostring(#facts.queue), "muted") } }),
		list,
	})
end

local function log_block(state: any): any
	local lines = {}
	for i, entry in state.log do
		if i > 40 then
			break
		end
		table.insert(lines, line({
			t(entry.t .. " ", "muted"),
			t(entry.who .. " ", if entry.who == "agent" then "info" else "accent"),
			entry.text,
		}))
	end
	if #lines == 0 then
		table.insert(lines, line({ t("agent 和你的每次操作都会记录在这里", "muted") }))
	end
	return block("log", "5", "活动日志", nil, lines, { role = "fl.block.log" })
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
				table.insert(nodes, line({ t("[图片加载中…]", "muted") }, { key = key }))
			end
		end
	end
	return ui.node("col", { key = "images", gap = "xs" }, nodes)
end

local function thread_block(state: any, item: any): any
	local messages = {}
	local thread = item.thread or { { sender = item.name, time = item.time, content = item.content, id = item.id } }
	for i, message in thread do
		local hit = message.id == item.id
		table.insert(messages, ui.node("col", { key = tostring(i), role = if hit then "fl.msg.hit" else "fl.msg", gap = "none" }, {
			ui.node("row", { justify = "between" }, {
				line({ t(message.sender, "strong") }),
				line({ t((if hit then "触发 · " else "") .. tostring(message.time), "muted") }),
			}),
			line(if message.deleted then { t("[消息已撤回]", "muted") } else feishu.clean(tostring(message.content))),
			images_of(state, message),
		}))
	end
	if item.thread_error then
		table.insert(messages, line({ t("未能读取会话上下文：" .. item.thread_error, "muted") }))
	end
	return block("thread", "6", "原消息", item.chat, messages, {})
end

local function analysis_block(state: any, item: any): any
	local a = item.analysis
	local meta, children
	local status = view.status(item)
	if a and a.manual then
		meta = "手写"
		children = { line({ t("这条回复由你手写，agent 没有参与。按 g 交给 omp。", "muted") }) }
	elseif a then
		local filled = math.floor(a.conf * 10 + 0.5)
		meta = "把握 " .. string.rep("█", filled) .. string.rep("░", 10 - filled) .. " " .. tostring(math.floor(a.conf * 100 + 0.5)) .. "%"
		children = {
			line({ t(a.summary, "strong") }),
			ui.kv({
				{ { t("意图", "muted") }, a.intent },
				{ { t("紧急", "muted") }, a.urgency },
				{ { t("建议", "muted") }, { t(a.advice, "info") } },
			}),
		}
		if #a.evidence > 0 then
			table.insert(children, line({ t("依据", "muted") }, { role = "fl.section" }))
			for _, entry in a.evidence do
				table.insert(children, line({ t("[" .. entry.tag .. "] ", "info"), entry.text }))
			end
		end
		if a.risk ~= "" then
			table.insert(children, line({ t("agent 不确定 ", "warning strong"), a.risk }, { role = "fl.warn" }))
		end
	elseif status == "failed" then
		meta = "失败"
		children = {
			line({ t("分析失败", "warning strong") }),
			line(tostring(item.agent_error)),
			ui.node("row", {}, { ui.button("重试", { key = "retry", keys = { "r" }, actions = { click = "retry" } }) }),
		}
	elseif status == "running" then
		meta = "分析中"
		children = {
			line({ t("● 正在分析这条消息", "info") }),
			line({ t("$ ", "info"), t("读取会话上下文和今日日程", "muted") }),
			line({ t("$ ", "info"), t("结合其他待处理消息生成回复", "muted") }),
		}
	else
		meta = view.STATUS[status][1]
		local why = if status == "manual" then "按设置，这条不交给 agent。按 g 交给 omp，或按 e 手写回复。"
			elseif not settings.get("agent_enabled") then "自动分析已关闭。按 g 交给 omp，或按 e 手写回复。"
			else "这条消息还没有分析，选中后会排队。"
		children = { line({ t(why, "muted") }) }
	end
	local talk = item.talk or {}
	if #talk > 0 or state.talking == item.id then
		table.insert(children, line({ t("对话", "muted") }, { role = "fl.section" }))
		for _, entry in talk do
			table.insert(children, line({
				t(if entry.me then "你 " else "omp ", if entry.me then "accent" else "info"),
				entry.text,
			}, { role = "fl.talk" }))
		end
		if state.talking == item.id then
			table.insert(children, line({ t("● omp 正在回答…", "info") }, { role = "fl.talk" }))
		end
	end
	return block("analysis", "7", "agent 分析", meta, children, {})
end

local function reply_block(state: any, item: any, facts: any): any
	local status = view.status(item)
	local locked = view.locked(item)
	local drafts = item.analysis and item.analysis.drafts or {}
	local has_drafts = #drafts > 0
	local children: { any } = {}
	if has_drafts then
		local tabs = {}
		for i, draft in drafts do
			table.insert(tabs, ui.button(draft.label, {
				key = "tab" .. tostring(i),
				size = "sm",
				on = i == item.variant,
				actions = { click = "variant=" .. tostring(i) },
				disabled = locked,
			}))
		end
		if item.edited then
			table.insert(tabs, line({ t("已手动修改", "accent") }))
		end
		table.insert(children, ui.node("row", { key = "tabs", gap = "sm", wrap = true }, tabs))
		table.insert(children, ui.node("editor", {
			key = "draft",
			role = "fl.draft",
			text = facts.draft,
			cursor = state.draft_cursor,
			readonly = locked or state.mode ~= "draft",
			maxLines = 5,
			placeholder = "回复内容",
		}))
	else
		local why = if status == "running" or status == "queued" then "分析完成后，这里会出现拟定回复。"
			elseif status == "failed" then "分析失败，没有拟定回复。按 e 手写。"
			elseif status == "manual" then "没有拟定回复。按 e 手写。"
			else "agent 认为这条不需要回复。按 e 手写。"
		table.insert(children, line({ t(why, "muted") }))
	end
	local can_decide = not locked and item.analysis ~= nil
	local primary = if status == "sent" then "已发送"
		elseif status == "archived" then "已归档"
		elseif has_drafts then "通过并发送"
		else "通过并归档"
	if item.send_error then
		table.insert(children, line({ t("发送失败 ", "warning strong"), item.send_error }, { role = "fl.warn" }))
	end
	local actions = ui.node("row", { key = "actions", role = "fl.foot", gap = "sm", wrap = true }, {
		ui.button(primary, { key = "approve", variant = "primary", keys = { "a" }, actions = { click = "approve" }, disabled = not can_decide }),
		ui.button("修改", { key = "edit", keys = { "e" }, actions = { click = "edit" }, disabled = locked or status == "running" }),
		ui.button("换一稿", { key = "redraft", keys = { "r" }, actions = { click = "redraft" }, disabled = locked or not has_drafts }),
		ui.button("稍后", { key = "snooze", keys = { "s" }, actions = { click = "snooze" }, disabled = locked }),
		ui.button("归档", { key = "archive", keys = { "x" }, actions = { click = "archive" }, disabled = locked }),
		ui.button("飞书", { key = "open", title = "在飞书中打开原消息", keys = { "⏎" }, actions = { click = "open" } }),
		ui.button("omp", { key = "omp", title = "在原生 omp 块中打开这条消息的会话", keys = { "o" }, actions = { click = "omp" }, disabled = not item.session }),
		ui.node("row", { grow = 1 }),
		line({ t(view.STATUS[status][1], view.STATUS[status][2]) }),
	})
	return block("reply", "8", "拟定回复", "回复到 " .. item.chat, children, { role = "fl.block.on" }, actions)
end

local function right(state: any, facts: any, stacked: boolean): any
	local item = facts.item
	if not item then
		return ui.node("col", { key = "right", role = "fl.column" }, {
			ui.node("col", { key = "empty", role = "fl.block", grow = 1 }, {
				line({ t("$ 选择队列里的一条消息，查看 agent 的分析和回复。", "muted") }, { role = "fl.empty" }),
			}),
		})
	end
	return ui.node("col", { key = "right", role = "fl.column", gap = "lg" }, {
		ui.node(if stacked then "col" else "row", { key = "top", role = "fl.top", gap = if stacked then "lg" else "md", align = "stretch" }, {
			thread_block(state, item),
			analysis_block(state, item),
		}),
		reply_block(state, item, facts),
	})
end

local function header(state: any, facts: any, cx: any): any
	local agent_text = if facts.running > 0 then "agent 分析中 " .. tostring(facts.running) else "agent 空闲"
	local spans: { any } = {
		t("tern-plugin-feishu", "accent strong"), t("  ~/inbox  ", "muted"),
		t(tostring(facts.pending), "accent"), " 待审核  ",
		t(tostring(facts.needs) .. " 需你决定", "warning"),
	}
	local right_spans: { any } = {
		t(agent_text, "info"), t("  发送前必须审核  ", "muted"),
		t(if state.loading then "检索中…" else os.date("%H:%M") :: string, "muted"),
	}
	local lines: { any } = {
		ui.node("row", { key = "bar", role = "fl.bar", justify = "between", wrap = true }, {
			line(spans),
			ui.node("row", { key = "actions", gap = "sm", wrap = true }, {
				line(right_spans),
				ui.button(if state.loading then "刷新中…" else "刷新消息列表", {
					key = "refresh", size = "sm", actions = { click = "refresh" },
					busy = state.loading, disabled = state.loading,
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
	if cx.cols < 150 then
		table.insert(lines, nav_strip(state, facts))
	end
	return ui.node("col", { key = "head", gap = "none" }, lines)
end

local KEYS = { "j/k 上下", "a 通过", "e 修改", "r 换稿", "s 稍后", "x 归档", "u 撤销", "/ 对话", "o omp", "g 分析", "* 星标", "i 忽略群", "n 不分析", "⇧R 刷新", ", 设置" }
local SETTINGS_KEYS = { "j/k 上下", "空格 切换", "←/→ 换值", "Esc 返回" }

local function dock(state: any, narrow: boolean): any
	local hints = {}
	if not narrow then
		for i, hint in (if state.page == "settings" then SETTINGS_KEYS else KEYS) do
			local k, label = string.match(hint, "^(%S+) (.+)$")
			table.insert(hints, t(k :: string, "strong"))
			table.insert(hints, t(" " .. (label :: string) .. "   ", "muted"))
		end
	end
	local flash: { any } = {}
	if state.flash then
		table.insert(flash, ui.node("text", { key = "flash", spans = { state.flash } }))
	end
	if state.undo then
		table.insert(flash, ui.button("撤销", { key = "undo", size = "sm", variant = "quiet", keys = { "u" }, actions = { click = "undo" } }))
	end
	return ui.node("col", { role = "fl.dock", gap = "none" }, {
		ui.node("row", { key = "cmd", role = "fl.cmd", gap = "sm", hidden = state.page == "settings" }, {
			line({ t("omp>", "info strong") }),
			ui.node("input", {
				key = "field",
				grow = 1,
				text = state.command,
				cursor = state.command_cursor,
				readonly = state.mode ~= "command",
				placeholder = "和 omp 聊这条消息，例如：他说的灰度指哪个？语气再直接一点，明确周五交付",
			}),
			ui.button("发送", { key = "run", size = "sm", variant = "quiet", actions = { click = "run-command" }, busy = state.talking ~= nil }),
		}),
		ui.node("row", { key = "status", role = "fl.status", justify = "between", wrap = true }, {
			line(hints),
			ui.node("row", { key = "flashes", gap = "sm" }, flash),
		}),
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
	return status == "sent" or status == "archived" or status == "sending" or status == "replied"
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
	if item.triage then
		return item.triage
	end
	if item.agent == "queued" and item.no_agent then
		return "manual"
	end
	if item.agent == "done" then
		return if item.analysis then item.analysis.state else "needs"
	end
	return item.agent
end

function view.render(state: any, facts: any, cx: any): any
	if state.page == "settings" then
		return {
			main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts, { cols = 200 }), view.settings_body(state) }),
			dock = dock(state, cx.cols < 96),
		}
	end
	local wide = cx.cols >= 150
	local medium = cx.cols >= 96
	local list_cells = if wide then math.floor((cx.cols - 26) * 0.32) else if medium then 38 else cx.cols - 12
	-- A narrow window stacks everything, so the log gives its height to the details.
	local middle_blocks = { queue_block(state, facts, list_cells) }
	if medium then
		table.insert(middle_blocks, log_block(state))
	end
	local middle = ui.node("col", {
		key = "middle",
		role = if wide then "fl.column.middle" else "fl.column",
		gap = "lg",
	}, middle_blocks)
	local parts: { any } = {}
	if wide then
		table.insert(parts, left(state, facts))
	end
	table.insert(parts, middle)
	-- Message over analysis only where both still get a useful height.
	table.insert(parts, right(state, facts, medium and not wide and cx.rows >= 45))
	local body = ui.node(if medium then "row" else "col", {
		key = "body", role = if medium then "fl.layout" else "fl.layout.stack", gap = "md", align = "stretch",
	}, parts)
	return {
		main = ui.node("col", { role = "fl.root", gap = "none" }, { header(state, facts, cx), body }),
		dock = dock(state, not medium),
	}
end

return view

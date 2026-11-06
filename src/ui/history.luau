-- The old @me panel, inside the workbench. No queue actions or AI controls here.
local p = require("./primitives")
local history = require("../core/history")
local ui, t, line = p.ui, p.t, p.line
local history_ui = {}

local function sender(message)
	local from = message.sender
	return if type(from) == "table" then tostring(from.name or from.id or "未知发送者") else "未知发送者"
end

function history_ui.body(model)
	local h = model.history or history.empty()
	local page = history.page(h)
	local children = {
		line({ t("@我历史", "title strong") }),
		line({ t("全部可检索历史 · 含 @所有人 · 只读，不进入分析队列", "muted") }),
	}
	if h.loading then table.insert(children, ui.progress(nil, "正在检索飞书消息…")) end
	if h.error then
		table.insert(children, ui.card({ t("检索失败", "error") }, {
			line(h.error), ui.button("重试", { key = "retry", actions = { click = "history-retry" }, disabled = h.loading }),
		}))
	end
	if page then
		local rows = {}
		for index, message in page.messages do
			table.insert(rows, { id = tostring(index), cells = {
				tostring(message.create_time or ""), sender(message), tostring(message.chat_name or message.chat_id or "未知会话"),
				if message.deleted then "[消息已撤回]" else tostring(message.content or "[无正文]"),
			} })
		end
		local listing = ui.table({
			{ id = "time", head = "时间", priority = 2 }, { id = "sender", head = "发送者", priority = 3 },
			{ id = "chat", head = "会话", priority = 1 }, { id = "content", head = "消息", grow = 1, priority = 4 },
		}, rows, { selectable = true, selected = tostring(h.selected), empty = "这一页没有匹配消息" })
		listing.p = listing.p or {}; listing.p.key = "table"
		table.insert(children, ui.node("scroll", { key = "messages", max = { h = "18lines" } }, { listing }))
		local message = history.selected(h)
		if message then
			table.insert(children, ui.card(sender(message), {
				line({ t(tostring(message.chat_name or message.chat_id or "") .. " · " .. tostring(message.create_time or ""), "muted") }),
				line(if message.deleted then "[消息已撤回]" else tostring(message.content or "[无正文]")),
				ui.row({
					ui.button("在飞书中打开", { key = "open", variant = "primary", keys = { "enter" }, actions = { click = "history-open-message" } }),
					ui.button("复制正文", { key = "copy", keys = { "c" }, actions = { click = "history-copy-message" }, disabled = message.deleted == true }),
				}),
			}, { key = "detail" }))
		end
		if not page.has_more and h.index == #h.pages then table.insert(children, line({ t("已到达全部可检索结果末尾", "muted") })) end
	elseif not h.loading and not h.error then table.insert(children, line("没有 @我的消息")) end
	return ui.node("scroll", { key = "history", role = "fl.history" }, {
		ui.node("col", { gap = "sm" }, children),
	})
end

function history_ui.dock(model)
	local h = model.history or history.empty()
	local page = history.page(h)
	return ui.node("row", { role = "fl.dock", gap = "sm", wrap = true }, {
		ui.button("刷新", { key = "refresh", keys = { "r" }, actions = { click = "history-refresh" }, disabled = h.loading }),
		ui.button("上一页", { key = "previous", keys = { "p" }, actions = { click = "history-previous" }, disabled = h.loading or h.index <= 1 }),
		ui.button("下一页", { key = "next", keys = { "n" }, actions = { click = "history-next" }, disabled = h.loading or not page or (h.index == #h.pages and not page.has_more) }),
		line({ t("第 " .. tostring(h.index) .. " 页 · 本页 " .. tostring(if page then #page.messages else 0) .. " 条", "muted") }),
	})
end

return history_ui

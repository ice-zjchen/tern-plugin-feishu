local p = require("./primitives")
local ids = require("./ids")
local status = require("../core/status")
local markup = require("../shared/markup")
local text = require("../shared/text")
local time = require("../shared/time")
local ui, t, line = p.ui, p.t, p.line

local queue = {}

function queue.sources(model: any): any
	local sources = {}
	for _, source in { { "all", "全部" }, { "mention", "@我" }, { "dm", "私聊" } } do
		table.insert(sources, ui.button(source[2], {
			key = source[1],
			role = if (model.source or "all") == source[1] then "fl.source.current" else "fl.source",
			variant = "quiet", on = (model.source or "all") == source[1],
			actions = { click = "source=" .. source[1] },
		}))
	end
	return ui.node("row", { key = "sources", role = "fl.sources", gap = "xs", wrap = true }, sources)
end

local function foot(model: any, facts: any): any?
	local count = 0
	for _, def in facts.views do
		if def.id == "fyi" then
			count = def.count
		end
	end
	if model.view == "fyi" and not model.person then
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

function queue.render(model: any, facts: any, list_cells: number): any
	local items = {}
	for _, item in facts.queue do
		local label_status = status.LABELS[status.of(item)]
		local judgment = item.analysis.judgment
		local timestamp, full_time = time.format(item.time)
		local summary = if judgment and not judgment.manual and judgment.summary ~= "" then judgment.summary else markup.clean(item.content)
		if item.task and item.task.new_messages > 0 then
			label_status = { "任务期间有新消息", "warning" }
		end
		local where = if item.chat_type == "p2p" then "私聊" else item.chat
		local label: { any } = {
			text.fit(summary, math.max(6, list_cells - 6)) .. "\n",
			t(text.fit(item.name .. " · " .. where, math.max(6, list_cells - text.cells(label_status[1]) - 4)), "muted"),
		}
		if status.unread(item) then
			table.insert(label, t(" ●", "accent"))
		elseif item.is_read == nil and not status.settled(item) then
			table.insert(label, t(" ?", "muted"))
		end
		if status.message_count(item) > 1 then
			table.insert(label, t(" · " .. tostring(status.message_count(item)) .. " 条", "muted"))
		end
		table.insert(items, ui.node("item", {
			key = item.id, role = "fl.queue.message", title = full_time, label = label,
			value = { t(timestamp, "muted"), "\n", t(label_status[1], label_status[2]) },
		}))
	end
	local children: { any } = {
		ui.node("list", {
			key = "items", role = "fl.queue",
			selected = if model.selected then ids.QUEUE_PREFIX .. model.selected else nil,
			empty = { t(if model.loading then "正在检索飞书消息…" else "这里没有消息了。", "muted") },
			max = 1, grow = 1,
		}, items),
	}
	if facts.has_more then
		table.insert(children, ui.node("row", { key = "more", role = "fl.queue.foot", justify = "between", gap = "sm" }, {
			line({ t("还有更早的消息", "muted") }),
			ui.button(if model.loading_more then "加载中…" else "加载更早", {
				key = "load", size = "sm", variant = "quiet", keys = { "m" },
				actions = { click = "load-more" }, busy = model.loading_more == true, disabled = model.loading == true,
			}),
		}))
	end
	local footer = foot(model, facts)
	if footer then
		table.insert(children, footer)
	end
	return ui.node("col", { key = "queue", role = "fl.queue.panel", grow = 1, gap = "none" }, children)
end

return queue

-- Pure workbench rendering. Styles live in styles/inbox.css; focus stays in runtime.
local p = require("./primitives")
local layout = require("./layout")
local queue = require("./queue")
local detail = require("./detail")
local thread = require("./thread")
local settings = require("./settings")
local history = require("./history")
local ui, t, line = p.ui, p.t, p.line

local inbox = {}

-- Pane widths in cells. The conversation folds away before any of the three
-- columns gets squeezed; below TWO_PANES (a phone, about 690px) the queue and
-- the selected message take turns on the whole pane.
local THREE_PANES = 170
local TWO_PANES = 80
local SHORT_HINTS = 110

local function root(compact: boolean, children: { any }): any
	return ui.node("col", { role = if compact then "fl.root.compact" else "fl.root", gap = "none" }, children)
end

local function context(model: any, item: any): any
	local side: { any } = { thread.render(model, item) }
	local why = detail.why(item)
	if why then
		table.insert(side, ui.node("col", { key = "why", role = "fl.context.why", gap = "sm" }, {
			line({ t("判断理由", "strong") }),
			line(why, { role = "fl.context.text" }),
		}))
	end
	local record = detail.record(model, item)
	if record then
		table.insert(side, record)
	end
	return ui.node("col", { key = "context", role = "fl.context", gap = "lg" }, side)
end

-- Phone width: the queue, or the message it opened with a way back.
local function single(model: any, facts: any, cx: any): any
	local dock = layout.dock(model, facts, "compact")
	local layer = if facts.dialog_item then thread.dialog(model, facts.dialog_item, true) else nil
	if model.reading and facts.item then
		local body = ui.node("col", { key = "body", role = "fl.layout.single", gap = "none" }, {
			detail.render(model, facts, false),
		})
		return { main = root(true, { layout.reader(model, facts), body }), dock = dock, layer = layer }
	end
	local middle = ui.node("col", { key = "middle", role = "fl.sidebar", gap = "none" }, {
		queue.render(model, facts, math.max(12, cx.cols - 8)),
	})
	local body = ui.node("col", { key = "body", role = "fl.layout.single", gap = "none" }, { middle })
	return { main = root(true, { layout.header(model, facts, true, queue.sources(model)), body }), dock = dock, layer = layer }
end

function inbox.render(model: any, facts: any, cx: any): any
	local compact = cx.cols < TWO_PANES
	local density = if compact then "compact" elseif cx.cols < SHORT_HINTS then "narrow" else "wide"
	if model.page == "settings" then
		return {
			main = root(compact, {
				layout.header(model, facts, compact, line({ t("设置", "strong") }, { key = "title" })),
				settings.render(model),
			}),
			dock = layout.dock(model, facts, density),
		}
	end
	if model.page == "history" then
		return {
			main = root(compact, { layout.header(model, facts, compact), history.body(model, compact) }),
			dock = history.dock(model, compact),
		}
	end
	if compact then
		return single(model, facts, cx)
	end
	local wide = cx.cols >= THREE_PANES
	local narrow = density == "narrow"
	local middle = ui.node("col", { key = "middle", role = "fl.sidebar", gap = "none" }, {
		queue.sources(model),
		queue.render(model, facts, if narrow then 36 else 44),
	})
	local parts: { any } = { middle, detail.render(model, facts, wide) }
	if wide and facts.item then
		table.insert(parts, context(model, facts.item))
	end
	local body = ui.node("row", {
		key = "body", role = if narrow then "fl.layout.narrow" else "fl.layout", gap = "none", align = "stretch",
	}, parts)
	return {
		main = root(false, { layout.header(model, facts, false), body }),
		dock = layout.dock(model, facts, density),
		layer = if facts.dialog_item then thread.dialog(model, facts.dialog_item, false) else nil,
	}
end

return inbox

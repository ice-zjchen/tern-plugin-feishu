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

-- The conversation folds away before any of the three columns gets squeezed.
local WIDE_COLS = 170
local WIDE_MEDIUM = 110

function inbox.render(model: any, facts: any, cx: any): any
	if model.page == "settings" then
		return {
			main = ui.node("col", { role = "fl.root", gap = "none" }, { layout.header(model, facts), settings.render(model) }),
			dock = layout.dock(model, facts, cx.cols < WIDE_MEDIUM),
		}
	end
	if model.page == "history" then
		return {
			main = ui.node("col", { role = "fl.root", gap = "none" }, { layout.header(model, facts), history.body(model) }),
			dock = history.dock(model),
		}
	end
	local wide = cx.cols >= WIDE_COLS
	local medium = cx.cols >= WIDE_MEDIUM
	local list_cells = math.max(12, if medium then 44 else cx.cols - 14)
	local middle = ui.node("col", { key = "middle", role = "fl.sidebar", gap = "none" }, {
		queue.sources(model),
		queue.render(model, facts, list_cells),
	})
	local parts: { any } = { middle, detail.render(model, facts, wide) }
	if wide and facts.item then
		local side: { any } = { thread.render(model, facts.item) }
		local why = detail.why(facts.item)
		if why then
			table.insert(side, ui.node("col", { key = "why", role = "fl.context.why", gap = "sm" }, {
				line({ t("判断理由", "strong") }),
				line(why, { role = "fl.context.text" }),
			}))
		end
		local record = detail.record(model, facts.item)
		if record then
			table.insert(side, record)
		end
		table.insert(parts, ui.node("col", { key = "context", role = "fl.context", gap = "lg" }, side))
	end
	local body = ui.node(if medium then "row" else "col", {
		key = "body", role = if medium then "fl.layout" else "fl.layout.stack", gap = "none", align = "stretch",
	}, parts)
	return {
		main = ui.node("col", { role = "fl.root", gap = "none" }, { layout.header(model, facts), body }),
		dock = layout.dock(model, facts, not medium),
		layer = if facts.dialog_item then thread.dialog(model, facts.dialog_item) else nil,
	}
end

return inbox

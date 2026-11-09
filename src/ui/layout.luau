local p = require("./primitives")
local status = require("../core/status")
local keymap = require("../shared/keymap")
local ui, t, line = p.ui, p.t, p.line

local layout = {}

local function nav_strip(model: any, facts: any, compact: boolean): any
	local tabs = {}
	for _, def in facts.views do
		if def.id == "pending" or def.id == "doing" or def.id == "later" or def.id == "done" then
			local current = model.page == nil and not model.person and model.view == def.id
			table.insert(tabs, ui.button(def.label .. " " .. tostring(def.count), {
				key = def.id, role = if current then "fl.nav.current" else "fl.nav", variant = "quiet", on = current,
				actions = { click = "view=" .. def.id },
			}))
		end
	end
	table.insert(tabs, ui.button("@我历史", { key = "history", variant = "quiet", on = model.page == "history", actions = { click = "history" } }))
	-- A phone keeps the tabs on one line and scrolls them sideways.
	return ui.node("row", { key = "tabs", role = if compact then "fl.tabs.scroll" else "fl.tabs", gap = "none", wrap = not compact }, tabs)
end

local function actions(model: any, facts: any, compact: boolean): any
	local nodes: { any } = {}
	if facts.running > 0 then
		table.insert(nodes, line({ t("● 分析中 " .. tostring(facts.running), "info") }))
		table.insert(nodes, ui.button("全部停止", { key = "stop-all", size = "sm", variant = "quiet",
			title = "停止所有正在进行的初判，并暂停自动分析", actions = { click = "stop-all" } }))
	elseif not compact then
		-- On a phone the paused state lives in settings; the row has room for the buttons only.
		table.insert(nodes, line({ t(if model.cfg.settings.agent_enabled then "分析空闲" else "自动分析已暂停", "muted") }))
	end
	table.insert(nodes, ui.button(if model.loading then "刷新中…" else "刷新", {
		key = "refresh", size = "sm", actions = { click = if model.page == "history" then "history-refresh" else "refresh" }, busy = model.loading, disabled = model.loading,
	}))
	table.insert(nodes, ui.button(if model.page ~= "settings" then "设置" elseif compact then "返回" else "返回工作台", {
		key = "settings", size = "sm", actions = { click = "settings" },
	}))
	return ui.node("row", { key = "actions", role = "fl.header.actions", gap = "sm", wrap = not compact }, nodes)
end

local function notices(model: any, lines: { any })
	if model.runtime_warning then
		table.insert(lines, line({ t(model.runtime_warning, "warning") }, { key = "runtime-warning", role = "fl.notice" }))
	end
	if model.event_warning then
		table.insert(lines, line({ t(model.event_warning, "warning") }, { key = "event-warning", role = "fl.notice" }))
	end
	if model.problem then
		table.insert(lines, line({ t("检索失败 ", "warning strong"), model.problem }, { key = "problem", role = "fl.notice" }))
	end
end

-- `compact` (a phone) puts the tabs on their own scrolling line and the buttons
-- on a toolbar line after `lead`, the queue's source filters when it is shown.
function layout.header(model: any, facts: any, compact: boolean, lead: any?): any
	local lines: { any }
	if compact then
		local tools: { any } = if lead then { lead } else {}
		table.insert(tools, actions(model, facts, true))
		lines = {
			ui.node("row", { key = "bar", role = "fl.bar.compact", gap = "none" }, { nav_strip(model, facts, true) }),
			ui.node("row", { key = "tools", role = "fl.toolbar", justify = "between", gap = "sm" }, tools),
		}
	else
		lines = {
			ui.node("row", { key = "bar", role = "fl.bar", justify = "between", gap = "md", wrap = true }, {
				nav_strip(model, facts, false),
				actions(model, facts, false),
			}),
		}
	end
	notices(model, lines)
	return ui.node("col", { key = "head", gap = "none" }, lines)
end

-- A phone's message page: back to the queue, where this message sits in it, and
-- the neighbours, since there is no list beside it to tap.
function layout.reader(model: any, facts: any): any
	local at, total = 0, #facts.queue
	for i, item in facts.queue do
		if item.id == model.selected then
			at = i
		end
	end
	local label = "队列"
	for _, def in facts.views do
		if def.id == model.view then
			label = def.label
		end
	end
	local lines: { any } = {
		ui.node("row", { key = "bar", role = "fl.bar.reader", justify = "between", gap = "sm" }, {
			ui.button("‹ " .. label, { key = "back", variant = "quiet", actions = { click = "back" } }),
			line({ t(tostring(at) .. " / " .. tostring(total), "muted") }, { key = "position", role = "fl.reader.position" }),
			ui.node("row", { key = "steps", gap = "xs" }, {
				ui.button("上一条", { key = "previous", variant = "quiet", disabled = at <= 1, actions = { click = "move=-1" } }),
				ui.button("下一条", { key = "next", variant = "quiet", disabled = at >= total, actions = { click = "move=1" } }),
			}),
		}),
	}
	notices(model, lines)
	return ui.node("col", { key = "head", gap = "none" }, lines)
end

-- `density`: "wide", "narrow" (short key hints) or "compact" (a phone: no key
-- hints at all, and no dock when there is nothing to report).
function layout.dock(model: any, facts: any, density: string): any?
	local activity: { any } = {}
	local latest = model.log[1]
	if model.flash then
		table.insert(activity, line(model.flash, { key = "flash", role = "fl.activity" }))
	elseif latest then
		table.insert(activity, line({ t(latest.t .. " ", "muted"), latest.text }, { key = "latest", role = "fl.activity" }))
	end
	if model.undo then
		table.insert(activity, ui.button("撤销", { key = "undo", size = "sm", variant = "quiet", keys = { "u" }, actions = { click = "undo" } }))
	end
	if density == "compact" then
		return if #activity > 0 then ui.node("row", { role = "fl.dock.compact", gap = "sm" }, {
			ui.node("row", { key = "activity", role = "fl.activity.row", gap = "sm" }, activity),
		}) else nil
	end
	local hints = {}
	local adjustable = facts.item ~= nil and status.can_adjust(facts.item)
	for _, hint in keymap.hints(model.page, adjustable, density == "narrow") do
		local k, label = string.match(hint, "^(%S+) (.+)$")
		table.insert(hints, t(k :: string, "strong"))
		table.insert(hints, t(" " .. (label :: string) .. "   ", "muted"))
	end
	return ui.node("row", { role = "fl.dock", justify = "between", gap = "sm", wrap = true }, {
		ui.node("row", { key = "activity", role = "fl.activity.row", gap = "sm" }, activity),
		line(hints, { key = "shortcuts", role = "fl.shortcuts" }),
	})
end

return layout

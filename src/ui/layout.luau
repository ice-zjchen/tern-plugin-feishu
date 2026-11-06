local p = require("./primitives")
local status = require("../core/status")
local keymap = require("../shared/keymap")
local ui, t, line = p.ui, p.t, p.line

local layout = {}

local function nav_strip(model: any, facts: any): any
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
	return ui.node("row", { key = "tabs", role = "fl.tabs", gap = "none", wrap = true }, tabs)
end

function layout.header(model: any, facts: any): any
	local activity = if facts.running > 0 then "● 分析中 " .. tostring(facts.running)
		elseif not model.cfg.settings.agent_enabled then "自动分析已暂停" else "分析空闲"
	local lines: { any } = {
		ui.node("row", { key = "bar", role = "fl.bar", justify = "between", gap = "md", wrap = true }, {
			nav_strip(model, facts),
			ui.node("row", { key = "actions", role = "fl.header.actions", gap = "sm", wrap = true }, {
				line({ t(activity, if facts.running > 0 then "info" else "muted") }),
				ui.button(if model.loading then "刷新中…" else "刷新", {
					key = "refresh", size = "sm", actions = { click = if model.page == "history" then "history-refresh" else "refresh" }, busy = model.loading, disabled = model.loading,
				}),
				ui.button(if model.page == "settings" then "返回工作台" else "设置", {
					key = "settings", size = "sm", actions = { click = "settings" },
				}),
			}),
		}),
	}
	if model.runtime_warning then
		table.insert(lines, line({ t(model.runtime_warning, "warning") }, { key = "runtime-warning", role = "fl.notice" }))
	end
	if model.problem then
		table.insert(lines, line({ t("检索失败 ", "warning strong"), model.problem }, { key = "problem", role = "fl.notice" }))
	end
	return ui.node("col", { key = "head", gap = "none" }, lines)
end


function layout.dock(model: any, facts: any, narrow: boolean): any
	local hints = {}
	local adjustable = facts.item ~= nil and status.can_adjust(facts.item)
	for _, hint in keymap.hints(model.page, adjustable, narrow) do
		local k, label = string.match(hint, "^(%S+) (.+)$")
		table.insert(hints, t(k :: string, "strong"))
		table.insert(hints, t(" " .. (label :: string) .. "   ", "muted"))
	end
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
	return ui.node("row", { role = "fl.dock", justify = "between", gap = "sm", wrap = true }, {
		ui.node("row", { key = "activity", role = "fl.activity.row", gap = "sm" }, activity),
		line(hints, { key = "shortcuts", role = "fl.shortcuts" }),
	})
end

return layout

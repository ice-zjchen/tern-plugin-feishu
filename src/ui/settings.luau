local p = require("./primitives")
local schema = require("../shared/schema")
local ui, t, line = p.ui, p.t, p.line

local settings = {}

local function field_row(model: any, field: any): any
	local value = model.cfg.settings[field.id]
	local current = model.settings_cursor == field.id
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
		local editing = model.mode == "setting" and current
		control = ui.node("col", { key = "wrap", gap = "xs" }, {
			line(field.label),
			ui.node("input", {
				key = "c", text = value, cursor = if editing then model.field_cursor else nil,
				placeholder = "点击或回车编辑",
			}),
			line({ t(field.hint or "", "muted") }),
		})
	end
	return ui.node("col", { key = "f_" .. field.id, role = if current then "fl.field.current" else "fl.field" }, { control })
end

local function group(key: string, number: string, title: string, meta: string?, rows: { any }): any
	local frame: { any } = {
		ui.node("text", { key = "title", role = "fl.title", spans = { t(number, "accent strong"), " " .. title } }),
	}
	if meta then
		table.insert(frame, ui.node("text", { key = "meta", role = "fl.meta", spans = { t(meta, "muted") } }))
	end
	table.insert(frame, ui.node("col", { key = "body", role = "fl.group.body", gap = "none" }, rows))
	return ui.node("col", { key = key, role = "fl.group", gap = "none" }, frame)
end

local function rules_block(model: any): any
	local rows = {}
	local rules = model.cfg.rules
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
			line({ tostring(rule.name), t(if rule.mode == "hide" then "  不显示" else "  不交给 AI 分析", "muted") }),
			ui.node("row", { key = "actions", gap = "xs" }, {
				ui.button(if rule.mode == "hide" then "改为不分析" else "改为不显示", { key = "mode", size = "sm", actions = { click = "rule-mode=" .. id } }),
				ui.button("移除", { key = "del", size = "sm", actions = { click = "rule-del=" .. id } }),
			}),
		}))
	end
	if #rows == 0 then
		table.insert(rows, line({ t("在队列里按 i 不显示某个会话，按 n 让它显示但不交给 AI 分析。", "muted") }))
	end
	return group("rules", "6", "会话规则", tostring(#ids) .. " 条", rows)
end

function settings.render(model: any): any
	local columns: { [string]: { any } } = { left = {}, right = {} }
	for _, def in schema.GROUPS do
		local rows = {}
		for _, field in schema.FIELDS do
			if field.group == def.id then
				table.insert(rows, field_row(model, field))
			end
		end
		table.insert(columns[def.column], group(def.id, def.number, def.title, nil, rows))
	end
	table.insert(columns.right, rules_block(model))
	return ui.node("row", { key = "settings", role = "fl.settings", wrap = true, align = "start" }, {
		ui.node("col", { key = "left", role = "fl.settings.column", gap = "none" }, columns.left),
		ui.node("col", { key = "right", role = "fl.settings.column", gap = "none" }, columns.right),
	})
end

return settings

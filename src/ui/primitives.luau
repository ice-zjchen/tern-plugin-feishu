-- Shared Tern nodes; renderers receive all data from the current model.
local ui = require("tern").ui

local primitives = { ui = ui }

function primitives.t(text: string, token: string?): any
	return ui.span(text, token)
end

function primitives.line(spans: any, props: any?): any
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

function primitives.folded(key: string, title: string, children: { any }): any
	local node = ui.section(title, children)
	node.p = node.p or {}
	node.p.key = key
	node.p.collapsed = true
	node.p.collapsible = true
	return node
end

function primitives.kv_row(label: string, value: any): any
	return { { primitives.t(label, "muted") }, if type(value) == "table" then value else { value } }
end

return primitives

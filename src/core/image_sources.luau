--!strict
-- Choose existing image resources, not inferred image contents.
local markup = require("../shared/markup")
local context = require("./context")
local sources = {}

function sources.describe(m: any, task: string?): { any }
	local current = m.latest_id or m.id
	local selected_explicit, trigger_image = false, false
	local result, seen = {}, {}
	local latest = nil
	local function add(id: string, content: string, deleted: boolean)
		if deleted then return end
		for _, key in markup.images(content, math.huge) do
			local identity = id .. ":" .. key
			if seen[identity] then continue end
			seen[identity], latest = true, id
			local explicit = context.has_locator(task or "", id) or context.has_locator(task or "", key)
			selected_explicit = selected_explicit or explicit
			trigger_image = trigger_image or id == current
			table.insert(result, { source_message_id = id, file_key = key,
				selected = id == current or explicit, status = "uninspected" })
		end
	end
	add(current, m.content, m.deleted == true)
	for _, message in m.thread or {} do add(message.id, message.content, message.deleted == true) end
	local refers_to_image = string.find(task or "", "截图", 1, true) or string.find(task or "", "上图", 1, true)
		or string.find(string.lower(task or ""), "screenshot", 1, true)
	if refers_to_image and not trigger_image and not selected_explicit then
		for _, entry in result do entry.selected = entry.source_message_id == latest end
	end
	return result
end

return sources

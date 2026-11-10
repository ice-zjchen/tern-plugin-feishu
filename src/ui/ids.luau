-- Stable control paths shared with the runtime's focus and input handling.
local schema = require("../shared/schema")

local ids = {
	DRAFT_ID = "main.body.right.reply.draft",
	COMMAND_ID = "main.body.right.reply.correction.input.field",
	QUEUE_PREFIX = "main.body.middle.queue.items.",
}

function ids.field_control_id(id: string): string
	local field = schema.field(id)
	local column = "left"
	for _, group in schema.GROUPS do
		if group.id == field.group then
			column = group.column
		end
	end
	return "main.settings." .. column .. "." .. field.group .. ".body.f_" .. id .. ".wrap.c"
end

return ids

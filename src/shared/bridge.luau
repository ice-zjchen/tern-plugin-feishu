-- The contract between the host half (workbench) and the window half (task
-- tabs). The host cannot open agent tabs, so it writes the task under
-- `task:<id>` and opens `LINK .. id`; the window launches it and records the
-- tab's state back into the same key.
local tern = require("tern")

local bridge = {}

bridge.LINK = "tern-plugin-feishu://task/"

-- The message id in a task link, or nil.
function bridge.id_of(url: string): string?
	return string.match(url, "^tern%-plugin%-feishu://task/([%w_%-]+)$")
end

-- One key per task, so the halves never overwrite each other's tasks.
function bridge.task(id: string): any
	local stored = tern.kv.get("task:" .. id)
	return if type(stored) == "table" then stored else nil
end

function bridge.set_task(id: string, task: any)
	tern.kv.set("task:" .. id, task)
end

return bridge

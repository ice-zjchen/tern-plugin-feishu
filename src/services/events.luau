-- Only the host owns this writer. Files are immutable; KV carries monotonic
-- sequence and per-request receipts, not an authorization or a message archive.
local tern = require("tern")
local protocol = require("../core/events")
local task_rules = require("../core/task")

local writer = protocol.writer({
	get = tern.kv.get,
	set = tern.kv.set,
	exists = function(path) return tern.fs.exists(tern.plugin.data .. "/" .. path) end,
	write = function(path, record)
		tern.fs.mkdir(tern.plugin.data .. "/workbench-events")
		tern.fs.write(tern.plugin.data .. "/" .. path, tern.json.encode(record))
	end,
})

local events = {}
function events.append(event)
	local record = table.clone(event)
	assert(type(record.workspace) == "string" and record.workspace ~= "", "工作台事件缺少实际运行 Workspace")
	return writer.append(record)
end

function events.confirmed(request, at, session)
	return events.append({ type = "task_confirmed", at = at, workspace = request.default_workspace,
		matter_id = request.matter_id, revision = request.revision, request_id = request.request_id, session = session,
		data = { task = request.task_text, title = request.title,
			execution_workspace = task_rules.workspace(request.workspace, request.default_workspace) } })
end

return events

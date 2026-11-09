--!strict
-- Single-host append protocol. Storage is injected so durability and replay rules
-- are deterministic without Tern, sessions, or third-party source payloads.
local task_rules = require("./task")
local events = {}

local function integer(value: any, minimum: number): boolean
	return type(value) == "number" and value >= minimum and value < 9007199254740991 and value % 1 == 0
end

function events.writer(storage: any): any
	local writer = {}
	function writer.append(event: any): any
		assert(type(event) == "table" and integer(event.at, 0) and integer(event.revision, 0), "工作台事件时间或修订号无效")
		assert(task_rules.valid_workspace(event.workspace) and event.workspace ~= "", "工作台事件默认目录无效")
		assert(type(event.matter_id) == "string" and event.matter_id ~= "" and type(event.data) == "table", "工作台事件事项无效")
		assert(event.type == "analysis" or event.type == "workbench_chat" or event.type == "task_confirmed" or event.type == "task_result", "工作台事件类型无效")
		assert(event.session == nil or type(event.session) == "string", "工作台事件会话无效")
		assert(event.request_id == nil or integer(event.request_id, 1), "工作台事件请求号无效")
		local receipt, previous = nil, nil
		if event.type == "task_confirmed" or event.type == "task_result" then
			assert(integer(event.request_id, 1), "任务事件缺少请求号")
			assert(type(event.data.task) == "string" and task_rules.valid_workspace(event.data.execution_workspace)
				and event.data.execution_workspace ~= "", "任务事件正文或目录无效")
			if event.type == "task_confirmed" then assert(type(event.data.title) == "string", "任务确认标题无效") end
			receipt = "workbench-event-request:" .. tostring(event.request_id)
			previous = storage.get(receipt)
			if event.type == "task_confirmed" then
				if previous then return nil end
			else
				-- Historical tasks cannot invent a confirmation after execution.
				if not previous or previous.workspace ~= event.workspace or previous.matter_id ~= event.matter_id then return nil end
				if previous.revision ~= event.revision or previous.task ~= event.data.task
					or previous.execution_workspace ~= event.data.execution_workspace then return nil end
				assert(event.data.phase == "done" or event.data.phase == "closed", "任务结果阶段无效")
				assert(type(event.data.final) == "string", "任务结果必须为文本")
				for _, final in previous.results do if final == event.data.final then return nil end end
			end
		end
		local sequence = storage.get("workbench-event-sequence") or 0
		assert(integer(sequence, 0), "工作台事件序号损坏")
		sequence += 1
		local path = "workbench-events/" .. tostring(sequence) .. ".json"
		assert(not storage.exists(path), "工作台事件文件已存在，拒绝覆盖")
		local record = table.clone(event)
		record.version, record.id = 1, "workbench:" .. tostring(sequence)
		-- Reserve first. A failed write leaves a harmless gap, never an overwrite.
		storage.set("workbench-event-sequence", sequence)
		storage.write(path, record)
		if receipt then
			if event.type == "task_confirmed" then
				storage.set(receipt, { workspace = event.workspace, matter_id = event.matter_id, revision = event.revision,
					task = event.data.task, execution_workspace = event.data.execution_workspace, results = {} })
			else
				-- Stored values may be read-only: Tern returns JSON arrays with a protected
				-- metatable, which table.clone rejects. Copy the fields instead.
				local results = {}
				for _, final in previous.results do table.insert(results, final) end
				table.insert(results, event.data.final)
				storage.set(receipt, { workspace = previous.workspace, matter_id = previous.matter_id, revision = previous.revision,
					task = previous.task, execution_workspace = previous.execution_workspace, results = results })
			end
		end
		return record
	end
	return writer
end

return events

--!strict
local t = require("./t")
local events = require("../src/core/events")

local function fixture(): (any, any, any, any)
	local kv, files = {}, {}
	local storage = {
		get = function(key) return kv[key] end,
		set = function(key, value) kv[key] = value end,
		exists = function(path) return files[path] ~= nil end,
		write = function(path, value) files[path] = value end,
	}
	local writer = events.writer(storage)
	return writer, kv, files, storage
end

local function event(kind: string, request_id: number?): any
	return { type = kind, at = 1794000000, workspace = "/workflow", matter_id = "synthetic-matter", revision = 4,
		request_id = request_id, data = if kind == "task_confirmed" then { task = "Inspect the target", title = "Inspect", execution_workspace = "/target" }
			elseif kind == "task_result" then { task = "Inspect the target", final = "Observed a result", execution_workspace = "/target", phase = "done" }
			else { user_said = "Only inspect", decision_before = "deep", result = { reply = "Updated", decision = "deep", draft = "", task = "Only inspect", risk = "" } } }
end

t.test("append reserves immutable monotonic files across writer recreation", function()
	local writer, kv, files, storage = fixture()
	local first = writer.append(event("workbench_chat"))
	t.eq(first.version, 1); t.eq(first.id, "workbench:1")
	t.eq(first.workspace, "/workflow"); t.eq(first.data.content, nil)
	writer = events.writer(storage)
	local second = writer.append(event("task_confirmed", 7))
	t.eq(second.id, "workbench:2"); t.eq(kv["workbench-event-sequence"], 2)
	t.eq(files["workbench-events/1.json"], first)
	kv["workbench-event-sequence"] = 0
	t.errors(function() writer.append(event("workbench_chat")) end, "拒绝覆盖")
	t.eq(files["workbench-events/1.json"], first)
end)

t.test("results require their durable same-workspace same-matter confirmation", function()
	local writer = fixture()
	t.eq(writer.append(event("task_result", 7)), nil)
	writer.append(event("task_confirmed", 7))
	local wrong = event("task_result", 7); wrong.workspace = "/unrelated"
	t.eq(writer.append(wrong), nil)
	wrong = event("task_result", 7); wrong.matter_id = "other"
	t.eq(writer.append(wrong), nil)
	t.eq(writer.append(event("task_result", 8)), nil)
	local result = writer.append(event("task_result", 7))
	t.eq(result.request_id, 7); t.eq(result.data.execution_workspace, "/target")
	t.eq(writer.append(event("task_confirmed", 7)), nil)
	t.eq(writer.append(event("task_result", 7)), nil)
	local closed = event("task_result", 7); closed.data.phase = "closed"
	t.eq(writer.append(closed), nil)
	local next_result = event("task_result", 7); next_result.data.final = "A new observed result"
	t.eq(writer.append(next_result).data.final, "A new observed result")
	t.eq(writer.append(event("task_result", 7)), nil)
end)

t.test("nonfinite event numbers and missing request ids never write", function()
	local writer, kv = fixture()
	for _, field in { "at", "revision", "request_id" } do
		for _, bad in { math.huge, -math.huge, 0 / 0 } do
			local value = event("task_confirmed", 1); value[field] = bad
			t.errors(function() writer.append(value) end, "")
		end
	end
	t.errors(function() writer.append(event("task_confirmed")) end, "请求号")
	t.eq(kv["workbench-event-sequence"], nil)
end)

t.test("a failed write consumes its sequence without publishing a receipt", function()
	local kv = {}
	local writer = events.writer({ get = function(key) return kv[key] end,
		set = function(key, value) kv[key] = value end, exists = function() return false end,
		write = function() error("storage unavailable") end })
	t.errors(function() writer.append(event("task_confirmed", 1)) end, "storage unavailable")
	t.eq(kv["workbench-event-sequence"], 1)
	t.eq(kv["workbench-event-request:1"], nil)
end)

t.done()

--!strict
local t = require("./t")
local task = require("../src/core/task")

t.test("only the confirmed task first line selects a workspace", function()
	t.eq(task.workspace("执行 Workspace：/repo\n审查 MR", "/default"), "/repo")
	t.eq(task.workspace("只读排查\n执行 Workspace：/untrusted", "/default"), "/default")
	t.eq(task.workspace(nil, "/default"), "/default")
	t.errors(function() task.workspace("执行 Workspace：  \n任务", "/default") end, "不能为空")
	t.errors(function() task.workspace("附加仓库：/old", "/default") end, "重新确认")
end)

t.test("workspace allowlist matches exactly the second table column", function()
	local registry = "| 项目 | 目录 | 备注 |\n| yes | `/allowed` | `/not-allowed` |\n文本 `/outside`\n"
	t.eq(task.allowed("/allowed", "/default", registry), true)
	t.eq(task.allowed("/default", "/default", registry), true)
	t.eq(task.allowed("/not-allowed", "/default", registry), false)
	t.eq(task.allowed("/outside", "/default", registry), false)
end)

t.test("initial idle does not finish a newly launched task", function()
	t.eq(task.transition({ began = false, state = "working" }, "idle", "old text"), nil)
	local working = task.transition({ began = false }, "working", nil)
	local idle = task.transition(working, "idle", "new result")
	t.eq(idle.state, "done"); t.eq(idle.result, "new result")
end)

t.test("closing a finished task keeps its result available", function()
	t.eq(task.transition({ state = "done", began = true }, "pane_closed", nil), nil)
	t.eq(task.transition({ state = "working" }, "pane_closed", nil).state, "closed")
	t.eq(task.transition({ state = "working" }, "waiting_input", nil).state, "waiting")
end)

t.test("repeated link or interrupted claim never replays a task", function()
	t.eq(task.route({ state = "starting" }, false), "start")
	t.eq(task.route({ state = "starting", launched = true }, false), "closed")
	t.eq(task.route({ state = "closed" }, false), "closed")
	t.eq(task.route({ state = "done" }, false), "closed")
	t.eq(task.route({ state = "working" }, true), "focus")
end)

t.test("old attempt state and pane cannot appear on a new task request", function()
	local request = { request_id = 2, prompt = "new task", task_text = "确认后的要求" }
	local old = { request_id = 1, state = "done", result = "old result", pane = 12 }
	local joined = task.join(request, old)
	t.eq(joined.state, "starting"); t.eq(joined.result, nil); t.eq(joined.pane, nil)
	t.eq(joined.prompt, "new task")
	local current = task.join(request, { request_id = 2, state = "working", pane = 13 })
	t.eq(current.state, "working"); t.eq(current.pane, 13)
	t.eq(old.result, "old result")
	t.eq(task.join(nil, old), nil)
end)

t.done()

--!strict
local t = require("./t")
local judgment = require("../src/core/judgment")
local matter = require("../src/core/matter")
local status = require("../src/core/status")

local function parsed(output: any)
	local value, err = judgment.parse(output)
	t.eq(err, nil)
	assert(value)
	return value
end

t.test("analysis maps the prompt decisions to Matter kinds", function()
	for decision, kind in ({ ignore = "fyi", reply = "reply", deep = "deep" } :: { [string]: string }) do
		local value = parsed({ decision = decision, priority = "P1", summary = "Review the change" })
		t.eq(value.kind, kind)
		t.eq(value.pri, "P1")
		t.eq(value.manual, false)
	end
end)

t.test("analysis keeps optional-field fallbacks without inventing a decision", function()
	local value = parsed({ decision = "deep", priority = "urgent", summary = "Investigate", draft = " \n", task = false })
	t.eq(value.pri, "P2")
	t.eq(value.draft, "")
	t.eq(value.risk, "")
	t.eq(value.task.title, "Investigate")
	t.eq(value.task.prompt, "Investigate")
	for _, output in { false, {}, { decision = "fyi" }, { decision = "unknown" }, { decision = 1 } } do
		local invalid, err = judgment.parse(output)
		t.eq(invalid, nil)
		t.eq(type(err), "string")
	end
end)

t.test("analysis preserves full drafts and explicit task details", function()
	local value = parsed({
		decision = "deep", priority = "P0", summary = "Deploy", why = "Waiting for a decision",
		draft = "I will review it first.\n", risk = "Publish release",
		task = { title = "Release review", prompt = "Review release 42; report whether it can ship." },
	})
	t.eq(value.why, "Waiting for a decision")
	t.eq(value.draft, "I will review it first.\n")
	t.eq(value.risk, "Publish release")
	t.eq(value.task.title, "Release review")
	t.eq(value.task.prompt, "Review release 42; report whether it can ship.")
end)

t.test("conversation empty fields leave drafts and judgments alone", function()
	local reply, change, err = judgment.change({ reply = "Understood.", decision = "", draft = "", task = "", risk = "" })
	t.eq(err, nil)
	t.eq(reply, "Understood.")
	assert(change)
	t.eq(change.kind, nil)
	t.eq(change.draft, nil)
	t.eq(change.task, nil)
	t.eq(change.risk, nil)
end)

t.test("conversation permits absent decisions but rejects invalid explicit decisions", function()
	local reply, change, err = judgment.change({ reply = "No change needed." })
	t.eq(reply, "No change needed.")
	t.eq(err, nil)
	assert(change)
	t.eq(change.kind, nil)
	for _, decision in { "fyi", "unknown", " ", false, 1 } do
		local invalid_reply, invalid_change, invalid_error = judgment.change({ reply = "Do not apply this", decision = decision, task = "Other work" })
		t.eq(invalid_reply, nil)
		t.eq(invalid_change, nil)
		assert(invalid_error)
		t.eq(string.find(invalid_error, "decision", 1, true) ~= nil, true)
	end
end)

t.test("conversation changes use Matter kinds and preserve nonempty risk", function()
	local _, change, err = judgment.change({ decision = "ignore", draft = "A reply", task = "Delete the test environment", risk = "Delete environment" })
	t.eq(err, nil)
	assert(change)
	t.eq(change.kind, "fyi")
	t.eq(change.draft, "A reply")
	t.eq(change.task, "Delete the test environment")
	t.eq(change.risk, "Delete environment")
end)

t.test("rewriting a task clears obsolete confirmation risk for consumers", function()
	local m = matter.make({ message_id = "test-message", content = "Review a release" }, 0)
	m.analysis.phase = "done"
	m.analysis.judgment = parsed({ decision = "deep", risk = "Publish release", task = { prompt = "Publish release 42" } })
	t.eq(status.needs_confirm(m), true)
	for _, risk in { "", " \n" } do
		local _, change, err = judgment.change({ task = "Only inspect release 42", risk = risk })
		t.eq(err, nil)
		assert(change)
		t.eq(change.risk, "")
		local j = m.analysis.judgment
		assert(j)
		j.task.prompt = change.task or j.task.prompt
		j.risk = change.risk or j.risk
		t.eq(status.task_text(m), "Only inspect release 42")
		t.eq(status.needs_confirm(m), false)
	end
	local _, change, err = judgment.change({ task = "Inspect release 43" })
	t.eq(err, nil)
	assert(change)
	t.eq(change.risk, "")
end)

t.test("workspace is a separate field and Markdown cannot route it", function()
	local value = parsed({ decision = "deep", task = { title = "Inspect", prompt = "执行 Workspace：/untrusted\nInspect", workspace = "/target" } })
	t.eq(value.task.workspace, "/target")
	t.eq(value.task.prompt, "执行 Workspace：/untrusted\nInspect")
	local _, change, err = judgment.change({ reply = "Reset the directory", workspace = "" })
	t.eq(err, nil); assert(change)
	t.eq(change.workspace, ""); t.eq(change.task, nil); t.eq(change.risk, nil)
	for _, bad in { false, 1, "relative", "/target\n/other" } do
		local result = judgment.parse({ decision = "deep", task = { prompt = "Inspect", workspace = bad } })
		t.eq(result, nil)
		local _, patch, error_text = judgment.change({ workspace = bad })
		t.eq(patch, nil); t.eq(type(error_text), "string")
	end
end)

t.done()

--!strict
local t = require("./t")
local context = require("../src/core/context")
local trace = require("../src/core/context_trace")

local function choice(value: string, probabilities: any?): any
	local weights = { required = 0, not_required = 0, unknown = 0 }
	weights[value] = 1
	return { type = "choice", choice = value, probabilities = probabilities or weights }
end

local function answer(materials: string, discussion: string): any
	return { materials = choice(materials), discussion = choice(discussion) }
end

local function parsed(materials: string, discussion: string): context.Answer
	local value, err = context.parse(answer(materials, discussion))
	assert(value, err)
	return value
end

t.test("independent requirements derive all deterministic plan combinations", function()
	for _, materials in { "required", "not_required", "unknown" } do
		for _, discussion in { "required", "not_required", "unknown" } do
			local expected = if materials == "unknown" or discussion == "unknown" then "unknown"
				elseif discussion == "required" then "conversation"
				elseif materials == "required" then "message" else "none"
			local value = parsed(materials, discussion)
			t.eq(value.plan, expected)
			t.eq(value.materials.choice, materials)
			t.eq(value.discussion.choice, discussion)
		end
	end
end)

t.test("partial unknown never resolves to none or grants broad retrieval", function()
	for _, pair in { { "unknown", "not_required" }, { "not_required", "unknown" }, { "required", "unknown" }, { "unknown", "required" } } do
		local value = parsed(pair[1], pair[2])
		t.eq(value.plan, "unknown")
		t.eq(type(context.blocker(value, {})), "string")
	end
end)

t.test("missing independent tool answers and legacy plans fail closed", function()
	for _, value in {
		false, {}, { relation = "strong" }, { context = choice("not_required") },
		{ materials = choice("not_required") }, { discussion = choice("not_required") },
		{ materials = choice("not_required"), discussion = { choice = "required" } },
	} do
		local result, err = context.parse(value)
		t.eq(result, nil); t.eq(type(err), "string")
	end
end)

t.test("each typed answer rejects invalid choices and probabilities", function()
	for _, field in { "materials", "discussion" } do
		for _, probabilities in {
			{ required = 1, not_required = 1, unknown = 1 },
			{ required = -1, not_required = 1, unknown = 1 },
			{ required = 0 / 0, not_required = 0, unknown = 0 },
			{ required = math.huge, not_required = 0, unknown = 0 },
			{ required = 1.01, not_required = 0, unknown = 0 },
			{ required = "1", not_required = 0, unknown = 0 },
			{ required = 1 },
		} do
			local value = answer("not_required", "not_required")
			value[field] = choice("required", probabilities)
			t.eq((context.parse(value)), nil)
		end
		local value = answer("not_required", "not_required")
		value[field] = choice("all-chats")
		t.eq((context.parse(value)), nil)
	end
end)

t.test("uncertain probabilities stay evidence rather than invented accuracy gates", function()
	local value = answer("required", "not_required")
	value.materials = choice("required", { required = 0.4, not_required = 0.3, unknown = 0.3 })
	local result = context.parse(value)
	assert(result)
	local probabilities = result.materials.probabilities
	assert(probabilities)
	t.eq(result.plan, "message"); t.eq(probabilities.required, 0.4)
	value.materials.probabilities.required = 0
	t.eq(probabilities.required, 0.4)
end)

t.test("only the exact current message locator suppresses duplicated context", function()
	for _, task in {
		"分析 message_id: om_current 的截图", "核实 https://example.test/?message_id=om_current&x=1",
		"om_current", "按 `om_current` 总结相关讨论",
	} do
		t.eq(context.has_locator(task, "om_current"), true)
	end
	for _, task in { "分析 om_old 的截图", "om_current_extra", "prefix_om_current", "无需聊天的代码审查" } do
		t.eq(context.has_locator(task, "om_current"), false)
	end
	t.eq(context.has_locator("任务", ""), false)
end)

t.test("a task locator does not stand in for required image contents", function()
	local task = "按 message_id: om_current 分析截图"
	t.eq(context.has_locator(task, "om_current"), true)
	local value = parsed("required", "not_required")
	t.eq(value.plan, "message")
	for _, status in { "uninspected", "failed" } do
		t.eq(type(context.blocker(value, { { selected = true, status = status } })), "string")
	end
	t.eq(context.blocker(value, { { selected = true, status = "inspected", facts = { "实际观察到的事实" } } }), nil)
end)

t.test("scope excludes unrelated thread images and permits non-image attachments", function()
	local materials = parsed("required", "not_required")
	t.eq(context.blocker(materials, {}), nil)
	t.eq(context.blocker(materials, { { selected = false, status = "failed" } }), nil)
	local standalone = parsed("not_required", "not_required")
	t.eq(standalone.plan, "none")
	t.eq(context.blocker(standalone, { { selected = true, status = "uninspected" } }), nil)
	local discussion = parsed("not_required", "required")
	t.eq(discussion.plan, "conversation")
	t.eq(context.blocker(discussion, { { selected = false, status = "uninspected" } }), nil)
end)

t.test("assistant or unrelated tool output cannot supply a context judgment", function()
	local state = trace.new()
	local value = answer("not_required", "not_required")
	trace.call(state, { id = "read", name = "read", arguments = {} })
	trace.result(state, "read", false, value)
	t.eq(state.answer, nil)
	trace.call(state, { id = "eval", name = "eval", arguments = { code = "print('not a judgment')" } })
	trace.result(state, "eval", false, value)
	t.eq(state.answer, nil)
end)

t.test("failed or malformed judge attempts invalidate preceding evidence", function()
	local state = trace.new()
	local value = answer("not_required", "not_required")
	trace.call(state, { id = "first", name = "eval", arguments = { code = "await judge(state, questions)" } })
	trace.result(state, "first", false, value)
	assert(state.answer)
	trace.call(state, { id = "second", name = "eval", arguments = { code = "await judge(state, questions)" } })
	t.eq(state.answer, nil)
	trace.result(state, "first", false, value)
	t.eq(state.answer, nil)
	trace.result(state, "second", true, value)
	t.eq(state.answer, nil)
	trace.result(state, "second", false, { materials = choice("not_required") })
	t.eq(state.answer, nil)
end)

t.test("visual assessment shares decisions without fabricated probabilities", function()
	local result, err = context.from_vision({ materials = "required", discussion = "not_required" })
	assert(result); t.eq(err, nil); t.eq(result.plan, "message")
	t.eq(result.materials.probabilities, nil)
	local unknown = context.from_vision({ materials = "unknown", discussion = "required" })
	assert(unknown); t.eq(unknown.plan, "unknown")
	t.eq((context.from_vision({ materials = "required" })), nil)
	t.eq((context.from_vision({ materials = true, discussion = "not_required" })), nil)
end)

t.test("task-selected images use vision directly while unrelated thread images do not", function()
	t.eq(context.use_vision({}), false)
	t.eq(context.use_vision({ { selected = false, status = "uninspected" } }), false)
	t.eq(context.use_vision({ { selected = true, status = "uninspected" } }), true)
	t.eq(context.use_vision({ { selected = true, status = "failed" } }), true)
	t.eq(context.use_vision({ { selected = true, status = "inspected", cached = true } }), true)
end)

t.done()

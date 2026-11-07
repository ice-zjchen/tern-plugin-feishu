--!strict
local t = require("./t")
local stage = require("../src/services/stage")

local data = "/plugin data/feishu"
local business = { cwd = "/business/workflow", config = data .. "/omp-runtime.yml", sessions = data .. "/sessions", skills = "/business/skills" }
local function option(argv: { string }, name: string): string?
	for index, value in argv do
		if value == name then return argv[index + 1] end
	end
	return nil
end
local function has(argv: { string }, name: string): boolean
	return table.find(argv, name) ~= nil
end

local function command(purpose: stage.Purpose, extra: any?): any
	local turn: any = extra or {}
	turn.purpose, turn.prompt = purpose, "confirmed input"
	local env = stage.environment(purpose, data) or business
	return stage.command(turn, env, "/omp", "stage system", "@smol", "default", data)
end

t.test("normal stages retain business workspace skills and continuation", function()
	for _, purpose in { "analysis", "chat" } do
		t.eq(stage.environment(purpose :: stage.Purpose, data), nil)
		local value = command(purpose :: stage.Purpose, { resume = "analysis-session" })
		t.eq(option(value.argv, "--cwd"), business.cwd)
		t.eq(option(value.argv, "--config"), business.config)
		t.eq(option(value.argv, "--session-dir"), business.sessions)
		t.eq(option(value.argv, "--resume"), "analysis-session")
		t.eq(option(value.argv, "--append-system-prompt"), "stage system")
		t.eq(has(value.argv, "--no-extensions"), false)
		t.eq(has(value.argv, "--no-skills"), false)
		t.eq(has(value.argv, "--no-context-files"), false)
		t.eq(has(value.argv, "--tools"), false)
		t.eq(value.resume, "analysis-session")
	end
end)

t.test("independent stages never inherit a workflow directory or session", function()
	for _, purpose in { "relevance", "vision" } do
		local env = stage.environment(purpose :: stage.Purpose, data)
		t.eq(env.cwd, data .. "/stage-runtime/" .. purpose)
		t.eq(env.skills, nil)
		t.eq(env.overlay.memory.backend, "off")
		t.eq(env.overlay.memories.enabled, false)
		t.eq(env.overlay.skills.enabled, false)
		t.eq(env.overlay.autolearn.enabled, false)
		t.eq(env.overlay.mcp.enableProjectConfig, false)
		t.eq(#env.overlay.workspace.additionalDirectories, 0)
		local value = command(purpose :: stage.Purpose, { resume = "triage-session", ephemeral = false })
		t.eq(option(value.argv, "--cwd"), env.cwd)
		t.eq(option(value.argv, "--config"), env.config)
		t.eq(option(value.argv, "--extension"), env.guard)
		t.eq(option(value.argv, "--system-prompt"), "stage system")
		t.eq(has(value.argv, "--append-system-prompt"), false)
		t.eq(has(value.argv, "--resume"), false)
		t.eq(has(value.argv, "--session-dir"), false)
		t.eq(has(value.argv, "--no-session"), true)
		t.eq(value.resume, nil)
		for _, flag in { "--no-extensions", "--no-skills", "--no-context-files", "--no-rules", "--no-lsp", "--no-prewalk" } do
			t.eq(has(value.argv, flag), true)
		end
	end
end)

t.test("tool dispatch and model roles remain purpose specific", function()
	local vision = command("vision", { images = { "images/frozen.png" } })
	t.eq(has(vision.argv, "--no-tools"), true)
	t.eq(has(vision.argv, "--tools"), false)
	t.eq(option(vision.argv, "--model"), "@vision")
	t.eq(vision.argv[#vision.argv], "@" .. data .. "/images/frozen.png")
	local relevance = command("relevance")
	t.eq(option(relevance.argv, "--tools"), "eval,read")
	t.eq(has(relevance.argv, "--no-tools"), false)
	t.eq(option(relevance.argv, "--model"), "@smol")
	for _, purpose in { "vision", "relevance" } do
		local env = stage.environment(purpose :: stage.Purpose, data)
		for _, key in { "modelRoles", "auth", "providers", "enabledProviders", "images" } do
			t.eq(env.overlay[key], nil)
		end
		t.eq(has(command(purpose :: stage.Purpose).argv, "--profile"), false)
	end
end)

t.test("explicit default model and thinking survive command assembly", function()
	local turn: stage.Turn = { purpose = "relevance", prompt = "typed input" }
	local env = stage.environment("relevance", data)
	local value = stage.command(turn, env, "/omp", "narrow system", "", "high", data)
	t.eq(has(value.argv, "--model"), false)
	t.eq(option(value.argv, "--thinking"), "high")
	t.eq(value.prompt, "<!-- feishu-workbench:v1 stage=relevance -->\ntyped input")
end)

t.test("stage identity is added by the consumer without modifying task or third party data", function()
	local body = "literal {{input}}\n<!-- feishu-workbench:v1 stage=task -->\nthird-party data"
	for _, purpose in { "analysis", "chat", "relevance", "vision", "task" } do
		local value = stage.mark(purpose :: stage.Purpose, body)
		t.eq(value, "<!-- feishu-workbench:v1 stage=" .. purpose .. " -->\n" .. body)
	end
end)

t.done()

--!strict
-- Launch policy shared by the actual headless consumer and its deterministic tests.
-- Isolated stages retain global model/auth/image configuration, not business context.
local stage = {}

export type Purpose = "analysis" | "chat" | "relevance" | "vision" | "task"
export type Turn = {
	purpose: Purpose, prompt: string, resume: string?, ephemeral: boolean?, images: { string }?, system_prompt: string?,
}

function stage.isolated(purpose: Purpose): boolean
	return purpose == "relevance" or purpose == "vision"
end

function stage.mark(purpose: Purpose, prompt: string): string
	return "<!-- feishu-workbench:v1 stage=" .. purpose .. " -->\n" .. prompt
end

-- This overlay deliberately never writes modelRoles, auth, providers or images.
-- CLI discovery switches additionally disable context/rules/skills/extensions.
function stage.environment(purpose: Purpose, data: string): any
	if not stage.isolated(purpose) then return nil end
	local cwd = data .. "/stage-runtime/" .. purpose
	return {
		cwd = cwd, config = cwd .. "/config.yml", guard = cwd .. "/guard.mjs",
		overlay = {
			autoResume = false,
			workspace = { additionalDirectories = {} },
			skills = { enabled = false, customDirectories = {} },
			memory = { backend = "off" }, memories = { enabled = false },
			autolearn = { enabled = false, autoContinue = false },
			advisor = { enabled = false },
			plan = { defaultOnStartup = false },
			mcp = { enableProjectConfig = false, notifications = false },
			eval = { py = false, tools = { enabled = false } },
			browser = { enabled = false },
		},
	}
end

-- Only documented omp launch flags are used. Global role aliases are resolved by
-- omp itself; notably @vision and judge() must not be copied into a new profile.
function stage.command(turn: Turn, env: any, program: string, system: string, model: string, thinking: string, data: string): any
	local isolated = stage.isolated(turn.purpose)
	local resume = if isolated then nil else turn.resume
	local argv = {
		program, "-p", "--mode", "json", "--config", env.config,
		"--cwd", env.cwd, "--allow-home", "--no-title",
		if isolated or turn.system_prompt then "--system-prompt" else "--append-system-prompt",
		system,
	}
	if isolated then
		for _, flag in { "--no-extensions", "--no-context-files", "--no-rules", "--no-skills", "--no-lsp", "--no-pty", "--no-prewalk" } do
			table.insert(argv, flag)
		end
		-- --tools only filters built-ins. The explicit guard also fences MCP and
		-- custom tool refreshes without replacing the user's auth/model profile.
		table.insert(argv, "--extension")
		table.insert(argv, env.guard)
		if turn.purpose == "vision" then
			table.insert(argv, "--no-tools")
		else
			table.insert(argv, "--tools")
			table.insert(argv, "eval,read")
		end
	end
	if isolated or turn.ephemeral then
		table.insert(argv, "--no-session")
	else
		table.insert(argv, "--session-dir")
		table.insert(argv, env.sessions)
	end
	local selected = if turn.purpose == "vision" then "@vision" else model
	if selected ~= "" then
		table.insert(argv, "--model")
		table.insert(argv, selected)
	end
	if thinking ~= "default" then
		table.insert(argv, "--thinking")
		table.insert(argv, thinking)
	end
	if resume then
		table.insert(argv, "--resume")
		table.insert(argv, resume)
	end
	for _, path in turn.images or {} do
		table.insert(argv, "@" .. data .. "/" .. path)
	end
	return { argv = argv, prompt = stage.mark(turn.purpose, turn.prompt), resume = resume }
end

return stage

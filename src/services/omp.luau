-- Headless omp turns: `omp -p --mode json` with the workbench's system prompt,
-- in the configured workspace, with the model chosen for the turn's purpose.
local tern = require("tern")
local settings = require("../shared/settings")
local launch = require("./launch")
local prompts = require("./prompts")
local text = require("../shared/text")

local omp = {}

local TIMEOUT_MS = 180000
local MAX_STEPS = 30

-- What a turn is for, and which setting picks its model ("" keeps omp's default).
export type Purpose = "analysis" | "chat" | "relevance"
local MODEL_SETTING: { [Purpose]: string } = {
	analysis = "model_analysis",
	chat = "model_chat",
	relevance = "model_relevance",
}

export type Turn = {
	prompt: string,
	purpose: Purpose,
	-- A session to continue; nil starts a new one.
	resume: string?,
	-- Paths relative to the plugin data folder.
	images: { string }?,
	-- No session file at all: for one-off judgments nothing should resume.
	ephemeral: boolean?,
}

export type Step = { tool: string, target: string?, failed: boolean? }
-- A record of the run taken from what omp reports, not from what the model says it did.
export type Run = {
	steps: { Step }, more_steps: number, model: string?, provider: string?, thinking: string?,
	cwd: string?, skills: string?, incremental: boolean?, seconds: number?, cost: number?, at: string?,
}

export type Done = (text: string?, session: string?, cost: number, err: string?, run: Run?) -> ()

-- A model's string field when it says something, else nil.
function omp.text_of(value: any): string?
	return if type(value) == "string" and string.find(value, "%S") then value else nil
end

-- The JSON object in a model's text, tolerating a code fence or stray words around it.
function omp.json_in(s: string): any
	local from = string.find(s, "{", 1, true)
	local to: number? = nil
	for at = #s, 1, -1 do
		if string.byte(s, at) == 125 then
			to = at
			break
		end
	end
	if not from or not to or to < from then
		return nil
	end
	local ok, value = pcall(tern.json.decode, string.sub(s, from, to))
	return if ok and type(value) == "table" then value else nil
end

-- What one tool call was about, in a form safe to show: where it looked, else what
-- it said it was doing. Never its code or command, which can hold anything.
local function step_of(part: any): any
	local arguments = if type(part.arguments) == "table" then part.arguments else {}
	local target = nil
	for _, key in { "path", "url", "query", "pattern", "title" } do
		target = target or omp.text_of(arguments[key])
	end
	target = target or omp.text_of(part.intent)
	return { tool = tostring(part.name or "?"), target = target and text.clip(text.flat(target), 120), id = part.id }
end

-- omp's JSON event stream: session id, last assistant text, total cost, failure, run record.
local function read_events(stdout: string): (string?, string?, number, string?, Run)
	local session, said, cost, failure = nil, nil, 0, nil
	local run: any = { steps = {}, more_steps = 0 }
	local by_call: { [any]: any } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local ok, event = pcall(tern.json.decode, line)
		if ok and type(event) == "table" then
			if event.type == "session" and type(event.id) == "string" then
				session = event.id
			elseif event.type == "thinking_level_changed" then
				run.thinking = omp.text_of(event.thinkingLevel) or run.thinking
			elseif event.type == "turn_end" and type(event.message) == "table" then
				local message = event.message
				run.model = omp.text_of(message.model) or run.model
				run.provider = omp.text_of(message.provider) or run.provider
				local content = if type(message.content) == "table" then message.content else {}
				local parts = {}
				for _, part in content do
					if type(part) == "table" and part.type == "toolCall" then
						if #run.steps < MAX_STEPS then
							local step = step_of(part)
							table.insert(run.steps, step)
							by_call[step.id] = step
						else
							run.more_steps += 1
						end
					elseif type(part) == "table" and part.type == "text" and type(part.text) == "string" then
						table.insert(parts, part.text)
					end
				end
				for _, result in (if type(event.toolResults) == "table" then event.toolResults else {}) do
					local step = type(result) == "table" and by_call[result.toolCallId]
					if step then
						step.failed = result.isError == true
					end
				end
				local usage = message.usage
				if type(usage) == "table" and type(usage.cost) == "table" then
					cost += tonumber(usage.cost.total) or 0
				end
				if message.stopReason == "error" then
					failure = tostring(message.errorMessage or "模型调用失败")
				end
				if #parts > 0 then
					said = table.concat(parts)
				end
			end
		end
	end
	for _, step in run.steps do
		step.id = nil
	end
	return session, said, cost, failure, run
end

local function first_error_line(stderr: string): string
	for line in string.gmatch(stderr, "[^\n]+") do
		if not string.find(line, "Still starting", 1, true) and not string.find(line, "logs:", 1, true)
			and not string.find(line, "Warning:", 1, true) then
			return string.sub(line, 1, 300)
		end
	end
	return "没有错误输出"
end

-- Runs one turn. `notice` gets the workspace fallback warning (or nil);
-- `done` gets the assistant's final text, the session, the cost and the run record.
function omp.turn(turn: Turn, notice: (string?) -> (), done: Done)
	local prepared, env = pcall(launch.prepare)
	if not prepared then
		done(nil, turn.resume, 0, "无法准备 AI 运行目录或配置：" .. tostring(env), nil)
		return
	end
	notice(env.warning)
	-- Extensions stay on: they can provide the configured default model.
	local argv = {
		launch.program(), "-p", "--mode", "json", "--config", env.config,
		"--cwd", env.cwd, "--allow-home", "--no-title",
		"--append-system-prompt", prompts.render("system", "main"),
	}
	if turn.ephemeral then
		table.insert(argv, "--no-session")
	else
		table.insert(argv, "--session-dir")
		table.insert(argv, env.sessions)
	end
	local model = settings.get(MODEL_SETTING[turn.purpose])
	if model ~= "" then
		table.insert(argv, "--model")
		table.insert(argv, model)
	end
	local thinking = settings.get("thinking")
	if thinking ~= "default" then
		table.insert(argv, "--thinking")
		table.insert(argv, thinking)
	end
	if turn.resume then
		table.insert(argv, "--resume")
		table.insert(argv, turn.resume)
	end
	-- Images live under the plugin's data folder; omp runs in the workspace.
	for _, path in turn.images or {} do
		table.insert(argv, "@" .. tern.plugin.data .. "/" .. path)
	end
	local began = os.time()
	local started = pcall(function()
		tern.process.run(argv, { cwd = env.cwd, env = { PATH = launch.path() }, stdin = turn.prompt, timeout_ms = TIMEOUT_MS }, function(result)
			local session, said, cost, failure, run = read_events(result.stdout or "")
			session = session or turn.resume
			run.cwd, run.skills, run.incremental = env.cwd, env.skills, turn.resume ~= nil
			run.thinking = run.thinking or thinking
			run.seconds, run.cost, run.at = os.time() - began, cost, os.date("%m-%d %H:%M") :: string
			if result.timed_out then
				done(nil, turn.resume, 0, "AI 超时（" .. tostring(TIMEOUT_MS // 1000) .. " 秒）。", run)
			elseif result.status ~= 0 then
				done(nil, session, cost, "AI 程序退出码 " .. tostring(result.status) .. "：" .. first_error_line(result.stderr), run)
			elseif failure then
				done(nil, session, cost, failure, run)
			elseif not said then
				done(nil, session, cost, "AI 没有返回内容。", run)
			else
				done(said, session, cost, nil, run)
			end
		end)
	end)
	if not started then
		done(nil, turn.resume, 0, "无法启动 AI 程序。请通过命令面板「飞书 Feishu / Lark：设置 AI 程序路径」指定可执行文件。", nil)
	end
end

-- Drops a session's files once its message is settled.
function omp.forget(session: string)
	pcall(function()
		local dir = tern.plugin.data .. "/sessions"
		for _, name in tern.fs.list(dir) do
			if string.find(name, session, 1, true) then
				tern.fs.remove(dir .. "/" .. name)
			end
		end
	end)
end

return omp

-- Headless omp turns with purpose-specific launch policy and output evidence.
local tern = require("tern")
local settings = require("../shared/settings")
local launch = require("./launch")
local prompts = require("./prompts")
local stage = require("./stage")
local text = require("../shared/text")
local context_trace = require("../core/context_trace")
local proc = require("./proc")

local omp = {}

local MAX_STEPS = 30

-- What a turn is for, and which setting picks its model ("" keeps omp's default).
export type Purpose = "analysis" | "chat" | "relevance" | "vision"
local MODEL_SETTING: { [string]: string } = {
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
	-- Replaces the default system prompt for specialized, non-triage turns.
	system_prompt: string?,
}

export type Step = { tool: string, target: string?, failed: boolean? }
-- A record of the run taken from what omp reports, not from what the model says it did.
export type Run = {
	steps: { Step }, more_steps: number, model: string?, provider: string?, thinking: string?,
	cwd: string?, skills: string?, incremental: boolean?, seconds: number?, cost: number?, at: string?,
	context_judgment: any,
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
	local trace = context_trace.new()
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
						context_trace.call(trace, part)
						run.context_judgment = trace.answer
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
					if type(result) == "table" and trace.calls[result.toolCallId] then
						local value = nil
						for _, part in result.content or {} do
							if part.type == "text" and type(part.text) == "string" then
								local parsed = omp.json_in(part.text)
								if parsed and type(parsed.materials) == "table" and type(parsed.discussion) == "table" then value = parsed end
							end
						end
						context_trace.result(trace, result.toolCallId, result.isError == true, value)
						run.context_judgment = trace.answer
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

-- Runs one turn and returns its stop token (nil when nothing was started).
-- `notice` gets the workspace fallback warning (or nil); `done` gets the
-- assistant's final text, the session, the cost and the run record.
function omp.turn(turn: Turn, notice: (string?) -> (), done: Done): string?
	local resume = if stage.isolated(turn.purpose) then nil else turn.resume
	local prepared, env = pcall(launch.prepare, turn.purpose)
	if not prepared then
		done(nil, resume, 0, "无法准备 AI 运行目录或配置：" .. tostring(env), nil)
		return nil
	end
	notice(env.warning)
	local system = turn.system_prompt or (if turn.purpose == "relevance" then prompts.render("context", "system")
		elseif turn.purpose == "vision" then prompts.render("vision", "assess_system")
		else prompts.render("system", "main"))
	local model = if turn.purpose == "vision" then "" else settings.get(MODEL_SETTING[turn.purpose])
	local thinking = settings.get("thinking")
	local command = stage.command(turn, env, launch.program(), system, model, thinking, tern.plugin.data)
	local process_env = { PATH = launch.path() }
	if stage.isolated(turn.purpose) then
		process_env.FEISHU_WORKBENCH_STAGE = turn.purpose
		process_env.FEISHU_WORKBENCH_SYSTEM_PROMPT = system
	end
	local began = os.time()
	local timeout_ms = settings.get("ai_timeout_minutes") * 60 * 1000
	local token = proc.run("omp", command.argv, { cwd = env.cwd, env = process_env, stdin = command.prompt, timeout_ms = timeout_ms }, function(result)
		local session, said, cost, failure, run = read_events(result.stdout or "")
		session = session or resume
		run.cwd, run.skills, run.incremental = env.cwd, env.skills, resume ~= nil
		run.thinking = run.thinking or thinking
		run.seconds, run.cost, run.at = os.time() - began, cost, os.date("%m-%d %H:%M") :: string
		if result.timed_out then
			done(nil, session, cost, "AI 超时（" .. tostring(timeout_ms // 60000) .. " 分钟），可在“运行”设置中延长后手动重试。", run)
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
	if not token then
		done(nil, resume, 0, "无法启动 AI 程序。请通过命令面板「飞书 Feishu / Lark：设置 AI 程序路径」指定可执行文件。", nil)
	end
	return token
end

-- Asks a running turn to stop: its tool processes first, then omp. The turn's
-- own callback reports the outcome; a turn that already ended is left alone.
omp.stop = proc.stop

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

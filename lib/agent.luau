-- Each message has an omp session using the workspace's normal instructions,
-- skills, tools and approval policy. The workbench adds its task/output contract.

local tern = require("tern")
local settings = require("./settings")
local runtime = require("./runtime")
local prompts = require("../src/services/prompts")
local text_util = require("../src/shared/text")

local agent = {}

local TIMEOUT_MS = 180000
local SESSIONS = "sessions"

-- omp by name last: a GUI-started daemon's PATH may not reach it.
local function command(): string
	local configured = tern.kv.get("agent")
	if type(configured) == "string" and configured ~= "" then
		return configured
	end
	local home = tern.getenv("HOME")
	for _, path in { if home then home .. "/.local/bin/omp" else "", "/opt/homebrew/bin/omp", "/usr/local/bin/omp" } do
		if path ~= "" and tern.fs.exists(path) then
			return path
		end
	end
	return "omp"
end

local STATE_OF = { ignore = "fyi", reply = "reply", deep = "deep" }

-- A model's string field when it says something, else nil.
local function text_of(value: any): string?
	return if type(value) == "string" and string.find(value, "%S") then value else nil
end

-- The object in a model's text, tolerating a code fence or stray words around it.
local function json_in(text: string): any
	local from = string.find(text, "{", 1, true)
	local to: number? = nil
	for at = #text, 1, -1 do
		if string.byte(text, at) == 125 then
			to = at
			break
		end
	end
	if not from or not to or to < from then
		return nil
	end
	local ok, value = pcall(tern.json.decode, string.sub(text, from, to))
	return if ok and type(value) == "table" then value else nil
end

local MAX_STEPS = 30

-- What one tool call was about, in a form safe to show: where it looked, else what
-- it said it was doing. Never its code or command, which can hold anything.
local function step_of(part: any): any
	local arguments = if type(part.arguments) == "table" then part.arguments else {}
	local target = nil
	for _, key in { "path", "url", "query", "pattern", "title" } do
		if not target then
			target = text_of(arguments[key])
		end
	end
	target = target or text_of(part.intent)
	return { tool = tostring(part.name or "?"), target = target and text_util.clip(text_util.flat(target), 120), id = part.id }
end

-- Reads omp's JSON event stream: session id, last assistant text, total cost, and a
-- record of the run taken from what omp reports, not from what the model says it did.
local function read_events(stdout: string): (string?, string?, number, string?, any)
	local session, text, cost, failure = nil, nil, 0, nil
	local run: any = { steps = {}, more_steps = 0 }
	local by_call: { [any]: any } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local ok, event = pcall(tern.json.decode, line)
		if ok and type(event) == "table" then
			if event.type == "session" and type(event.id) == "string" then
				session = event.id
			elseif event.type == "thinking_level_changed" then
				run.thinking = text_of(event.thinkingLevel) or run.thinking
			elseif event.type == "turn_end" and type(event.message) == "table" then
				local message = event.message
				run.model = text_of(message.model) or run.model
				run.provider = text_of(message.provider) or run.provider
				for _, part in (if type(message.content) == "table" then message.content else {}) do
					if type(part) == "table" and part.type == "toolCall" then
						if #run.steps < MAX_STEPS then
							local step = step_of(part)
							table.insert(run.steps, step)
							by_call[step.id] = step
						else
							run.more_steps += 1
						end
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
				if type(message.content) == "table" then
					local parts = {}
					for _, part in message.content do
						if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
							table.insert(parts, part.text)
						end
					end
					if #parts > 0 then
						text = table.concat(parts)
					end
				end
			end
		end
	end
	for _, step in run.steps do
		step.id = nil
	end
	return session, text, cost, failure, run
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

-- One omp turn. `done` gets the assistant's text, the session and the cost.
local function turn(prompt: string, resume: string?, images: { string }, notice: (string?) -> (), done: (string?, string?, number, string?, any) -> ())
	local prepared, launch = pcall(runtime.prepare)
	if not prepared then
		done(nil, resume, 0, "无法准备 AI 运行目录或配置：" .. tostring(launch))
		return
	end
	notice(launch.warning)
	-- Extensions stay on: they can provide the configured default model.
	local argv = {
		command(), "-p", "--mode", "json", "--config", launch.config,
		"--cwd", launch.cwd, "--allow-home", "--no-title",
		"--session-dir", launch.sessions, "--append-system-prompt", prompts.render("system", "main"),
	}
	local model = settings.get("model")
	if model ~= "" then
		table.insert(argv, "--model")
		table.insert(argv, model)
	end
	local thinking = settings.get("thinking")
	if thinking ~= "default" then
		table.insert(argv, "--thinking")
		table.insert(argv, thinking)
	end
	if resume then
		table.insert(argv, "--resume")
		table.insert(argv, resume)
	end
	-- Images live under the plugin's data folder; omp runs in the workspace.
	for _, path in images do
		table.insert(argv, "@" .. tern.plugin.data .. "/" .. path)
	end
	local began = os.time()
	local started = pcall(function()
		tern.process.run(argv, { cwd = launch.cwd, env = { PATH = runtime.path() }, stdin = prompt, timeout_ms = TIMEOUT_MS }, function(result)
			local session, text, cost, failure, run = read_events(result.stdout or "")
			run.cwd, run.skills, run.incremental = launch.cwd, launch.skills, resume ~= nil
			run.thinking = run.thinking or settings.get("thinking")
			run.seconds, run.cost, run.at = os.time() - began, cost, os.date("%m-%d %H:%M")
			if result.timed_out then
				done(nil, resume, 0, "AI 分析超时（" .. tostring(TIMEOUT_MS // 1000) .. " 秒）。", run)
				return
			end
			if result.status ~= 0 then
				done(nil, session or resume, cost, "AI 程序退出码 " .. tostring(result.status) .. "：" .. first_error_line(result.stderr), run)
			elseif failure then
				done(nil, session or resume, cost, failure, run)
			elseif not text then
				done(nil, session or resume, cost, "AI 没有返回内容。", run)
			else
				done(text, session or resume, cost, nil, run)
			end
		end)
	end)
	if not started then
		done(nil, resume, 0, "无法启动 AI 程序。请通过命令面板「飞书 Feishu / Lark：设置 AI 程序路径」指定可执行文件。")
	end
end

local function context(item: any, extras: any): string
	return tern.json.encode({
		trigger = {
			message_id = item.latest_id or item.id,
			chat_id = item.chat_id,
			sender = item.name,
			chat = item.chat,
			time = item.time,
			why = item.via,
			content = extras.clean(item.content),
		},
		thread = item.thread_for_agent,
		other_pending_messages = extras.others,
		today_agenda = extras.agenda or prompts.render("analysis", "no_agenda"),
		now = os.date("%Y-%m-%d %H:%M"),
	}, true)
end

-- The messages after `through` in what was read of the chat. Nil when `through`
-- has scrolled out of it, so the caller knows it can't tell what is new.
local function messages_after(item: any, through: string): { any }?
	local found, after = false, {}
	for _, message in item.thread_for_agent or {} do
		if found then
			table.insert(after, message)
		end
		found = found or message.id == through
	end
	return if found then after else nil
end

-- Analyzes a queue item. With a session that already judged this item and a way to
-- tell what is new, only that goes in: the session has the rest. Otherwise a new
-- session gets the whole context. `done` gets the analysis and session.
function agent.analyze(item: any, extras: any, images: { string }, done: (any, string?, number, string?, any) -> ())
	local new_messages = if item.session and item.analysis and item.analyzed_through then messages_after(item, item.analyzed_through) else nil
	local resume = if new_messages and #new_messages > 0 then item.session else nil
	local prompt
	if resume then
		prompt = prompts.render("analysis", "followup", {
			notes = if #images > 0 then prompts.render("analysis", "note_images_followup") else "",
			new_messages = tern.json.encode({ new_messages = new_messages, now = os.date("%Y-%m-%d %H:%M") }, true),
			format = prompts.render("analysis", "format"),
		})
	else
		prompt = prompts.render("analysis", "new", {
			notes = (if #item.folded > 0 and item.chat_type ~= "p2p" then prompts.render("analysis", "note_folded") else "")
				.. (if #images > 0 then prompts.render("analysis", "note_images_new") else ""),
			context = context(item, extras),
			format = prompts.render("analysis", "format"),
		})
	end
	turn(prompt, resume, images, extras.notice, function(text, session, cost, err, run)
		if err then
			done(nil, session, cost, err, run)
			return
		end
		local output = json_in(text :: string)
		if not output then
			done(nil, session, cost, "AI 返回的格式不对：" .. string.sub(text :: string, 1, 200), run)
			return
		end
		local state = STATE_OF[output.decision] or "reply"
		local task = if type(output.task) == "table" then output.task else {}
		local summary = tostring(output.summary or "")
		done({
			pri = if string.match(tostring(output.priority), "^P[0-3]$") then output.priority else "P2",
			state = state,
			summary = summary,
			why = tostring(output.why or ""),
			draft = text_of(output.draft) or "",
			risk = text_of(output.risk) or "",
			task = {
				title = text_of(task.title) or summary,
				prompt = text_of(task.prompt) or summary,
			},
		}, session, cost, nil, run)
	end)
end

-- One turn of conversation about a message, in its session when it has one.
-- `done` gets what the agent said and any changed judgment: { state, draft, task }.
function agent.converse(item: any, extras: any, current: any, said: string, done: (string?, any, string?, number, string?) -> ())
	local none = prompts.render("chat", "none")
	local prompt = prompts.render("chat", "turn", {
		said = said,
		decision = current.decision,
		draft = if current.draft ~= "" then current.draft else none,
		task = if current.task ~= "" then current.task else none,
		context = if item.session then "" else prompts.render("chat", "context", { context = context(item, extras) }),
		format = prompts.render("chat", "format"),
	})
	turn(prompt, item.session, {}, extras.notice, function(text, session, cost, err)
		if err then
			done(nil, nil, session, cost, err)
			return
		end
		local output = json_in(text :: string)
		if not output then
			-- Plain words are still an answer; the judgment just stays as it is.
			done(text, {}, session, cost, nil)
			return
		end
		done(tostring(output.reply or ""), {
			state = STATE_OF[output.decision],
			draft = text_of(output.draft),
			task = text_of(output.task),
			risk = text_of(output.risk),
		}, session, cost, nil)
	end)
end

-- Only a strongly related task gets a message locator and the trigger itself.
-- Nearby chat is fetched on demand, never copied wholesale into the execution tab.
local function task_prompt(item: any, clean: (string) -> string, task: string?, related: boolean): string
	local header = prompts.render("task", "header")
	local body = task or prompts.render("task", "open")
	if not related then
		return prompts.render("task", "weak", { header = header, task = body })
	end
	return prompts.render("task", "strong", {
		header = header,
		task = body,
		chat = if item.chat_type == "p2p" then prompts.render("task", "p2p", { name = item.name }) else item.chat,
		chat_id = item.chat_id,
		message_id = item.latest_id or item.id,
		time = item.time,
		now = os.date("%Y-%m-%d %H:%M") :: string,
		-- A message must not be able to close the block it is quoted in.
		content = (string.gsub(clean(item.content), "</?feishu_messages>", "")),
	})
end

-- Judge the final confirmed task, not a cached analysis that may predate edits.
-- A fresh, disposable session cannot inherit unrelated triage context.
function agent.prepare_task(item: any, clean: (string) -> string, task: string?, notice: (string?) -> (), done: (string?, number, string?) -> ())
	if not task then
		done(task_prompt(item, clean, nil, true), 0, nil)
		return
	end
	local prompt = prompts.render("relevance", "main", {
		state = tern.json.encode({
			task = task,
			trigger = { message_id = item.latest_id or item.id, content = clean(item.content) },
			thread = item.thread_for_agent,
		}, true),
	})
	turn(prompt, nil, {}, notice, function(text, session, cost, err)
		if session then
			agent.forget(session)
		end
		if err then
			done(nil, cost, err)
			return
		end
		local output = json_in(text :: string)
		if not output or (output.relation ~= "weak" and output.relation ~= "strong") then
			done(nil, cost, "AI 没有给出有效的任务关联性判断。")
			return
		end
		done(task_prompt(item, clean, task, output.relation == "strong"), cost, nil)
	end)
end

-- Drops a session's file once its message is settled.
function agent.forget(session: string)
	local dir = tern.plugin.data .. "/" .. SESSIONS
	pcall(function()
		for _, name in tern.fs.list(dir) do
			if string.find(name, session, 1, true) then
				tern.fs.remove(dir .. "/" .. name)
			end
		end
	end)
end


return agent

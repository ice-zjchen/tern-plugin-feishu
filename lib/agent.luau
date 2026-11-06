-- What the workbench asks AI: judge a message, talk about it, and decide how much
-- of the chat a confirmed task needs. Prompts come from prompts/; turns from omp.

local tern = require("tern")
local prompts = require("../src/services/prompts")
local omp = require("../src/services/omp")

local agent = {}

local STATE_OF = { ignore = "fyi", reply = "reply", deep = "deep" }
local text_of, json_in = omp.text_of, omp.json_in

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
	omp.turn({ prompt = prompt, purpose = "analysis", resume = resume, images = images }, extras.notice, function(text, session, cost, err, run)
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
	omp.turn({ prompt = prompt, purpose = "chat", resume = item.session }, extras.notice, function(text, session, cost, err)
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
	omp.turn({ prompt = prompt, purpose = "relevance", ephemeral = true }, notice, function(text, _session, cost, err)
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

agent.forget = omp.forget

return agent

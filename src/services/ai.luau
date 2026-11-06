-- What the workbench asks AI: judge a matter, talk about it, and decide how much
-- of the chat a confirmed task needs. Prompts come from prompts/; turns from omp.
local tern = require("tern")
local types = require("../core/types")
local matter = require("../core/matter")
local judgment = require("../core/judgment")
local markup = require("../shared/markup")
local prompts = require("./prompts")
local omp = require("./omp")

type Matter = types.Matter
export type Extras = { others: { any }?, agenda: any }
export type Current = { decision: string, draft: string, task: string }
type Notice = (string?) -> ()

local ai = {}

local function context(m: Matter, extras: Extras, thread: { any }): string
	return tern.json.encode({
		trigger = {
			message_id = m.latest_id or m.id,
			chat_id = m.chat_id,
			sender = m.name,
			chat = m.chat,
			time = m.time,
			why = m.via,
			content = markup.clean(m.content),
		},
		thread = thread,
		other_pending_messages = extras.others,
		today_agenda = extras.agenda or prompts.render("analysis", "no_agenda"),
		now = os.date("%Y-%m-%d %H:%M"),
	}, true)
end

-- Nil when the session's last message has scrolled out of the fetched thread:
-- only a known, nonempty suffix can safely continue that session.
local function messages_after(thread: { any }, through: string): { any }?
	local found, after = false, {}
	for _, message in thread do
		if found then
			table.insert(after, message)
		end
		found = found or message.id == through
	end
	return if found then after else nil
end

function ai.analyze(m: Matter, extras: Extras, images: { string }, notice: Notice, done: (types.Judgment?, string?, number, string?, omp.Run?) -> ())
	local a = m.analysis
	local thread = matter.agent_thread(m)
	local new_messages = if a.session and a.judgment and a.through then messages_after(thread, a.through) else nil
	local resume = if new_messages and #new_messages > 0 then a.session else nil
	local prompt
	if resume then
		prompt = prompts.render("analysis", "followup", {
			notes = if #images > 0 then prompts.render("analysis", "note_images_followup") else "",
			new_messages = tern.json.encode({ new_messages = new_messages, now = os.date("%Y-%m-%d %H:%M") }, true),
			format = prompts.render("analysis", "format"),
		})
	else
		prompt = prompts.render("analysis", "new", {
			notes = (if #m.folded > 0 and m.chat_type ~= "p2p" then prompts.render("analysis", "note_folded") else "")
				.. (if #images > 0 then prompts.render("analysis", "note_images_new") else ""),
			context = context(m, extras, thread),
			format = prompts.render("analysis", "format"),
		})
	end
	omp.turn({ prompt = prompt, purpose = "analysis", resume = resume, images = images }, notice, function(text, session, cost, err, run)
		if err then
			done(nil, session, cost, err, run)
			return
		end
		local output = omp.json_in(text or "")
		if not output then
			done(nil, session, cost, "AI 返回的格式不对：" .. string.sub(text or "", 1, 200), run)
			return
		end
		local parsed, parse_error = judgment.parse(output)
		done(parsed, session, cost, parse_error, run)
	end)
end

-- One turn about a matter, in its analysis session when it has one. The service
-- returns a patch; the caller applies it only if this request is still current.
function ai.converse(m: Matter, extras: Extras, current: Current, said: string, notice: Notice, done: (string?, judgment.Change?, string?, number, string?) -> ())
	local session = m.analysis.session
	local none = prompts.render("chat", "none")
	local prompt = prompts.render("chat", "turn", {
		said = said,
		decision = current.decision,
		draft = if current.draft ~= "" then current.draft else none,
		task = if current.task ~= "" then current.task else none,
		context = if session then "" else prompts.render("chat", "context", { context = context(m, extras, matter.agent_thread(m)) }),
		format = prompts.render("chat", "format"),
	})
	omp.turn({ prompt = prompt, purpose = "chat", resume = session }, notice, function(text, next_session, cost, err)
		if err then
			done(nil, nil, next_session, cost, err)
			return
		end
		local output = omp.json_in(text or "")
		if not output then
			-- Plain words are still an answer; the judgment just stays as it is.
			done(text, {}, next_session, cost, nil)
			return
		end
		local reply, change, parse_error = judgment.change(output)
		done(reply, change, next_session, cost, parse_error)
	end)
end

-- Only a strongly related task gets a message locator and the trigger itself.
-- Keep the task/Feishu headings from the templates: workspace selection reads them.
function ai.task_prompt(m: Matter, task: string?, related: boolean): string
	local header = prompts.render("task", "header")
	local body = task or prompts.render("task", "open")
	if not related then
		return prompts.render("task", "weak", { header = header, task = body })
	end
	return prompts.render("task", "strong", {
		header = header,
		task = body,
		chat = if m.chat_type == "p2p" then prompts.render("task", "p2p", { name = m.name }) else m.chat,
		chat_id = m.chat_id,
		message_id = m.latest_id or m.id,
		time = m.time,
		now = os.date("%Y-%m-%d %H:%M") :: string,
		-- A message must not be able to close the block it is quoted in.
		content = (string.gsub(markup.clean(m.content), "</?feishu_messages>", "")),
	})
end

-- Judge the final confirmed task, not a cached analysis that may predate edits.
-- A fresh, disposable session cannot inherit unrelated triage context.
function ai.prepare_task(m: Matter, task: string?, notice: Notice, done: (string?, number, string?) -> ())
	if not task then
		done(ai.task_prompt(m, nil, true), 0, nil)
		return
	end
	local prompt = prompts.render("relevance", "main", {
		state = tern.json.encode({
			task = task,
			trigger = { message_id = m.latest_id or m.id, content = markup.clean(m.content) },
			thread = matter.agent_thread(m),
		}, true),
	})
	omp.turn({ prompt = prompt, purpose = "relevance", ephemeral = true }, notice, function(text, _session, cost, err)
		if err then
			done(nil, cost, err)
			return
		end
		local output = omp.json_in(text or "")
		if not output or (output.relation ~= "weak" and output.relation ~= "strong") then
			done(nil, cost, "AI 没有给出有效的任务关联性判断。")
			return
		end
		done(ai.task_prompt(m, task, output.relation == "strong"), cost, nil)
	end)
end

return ai

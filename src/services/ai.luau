-- What the workbench asks AI: judge a matter, talk about it, and decide how much
-- of the chat a confirmed task needs. Prompts come from prompts/; turns from omp.
local tern = require("tern")
local types = require("../core/types")
local matter = require("../core/matter")
local judgment = require("../core/judgment")
local markup = require("../shared/markup")
local prompts = require("./prompts")
local omp = require("./omp")
local context_plan = require("../core/context")
local vision = require("./vision")
local stage = require("./stage")

type Matter = types.Matter
export type Extras = { others: { any }?, agenda: any }
export type Current = { decision: string, draft: string, task: string, workspace: string }
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
		if err then done(nil, session, cost, err, run); return end
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
function ai.converse(m: Matter, extras: Extras, current: Current, said: string, notice: Notice, done: (string?, judgment.Change?, string?, number, string?, omp.Run?) -> ())
	local session = m.analysis.session
	local none = prompts.render("chat", "none")
	local prompt = prompts.render("chat", "turn", {
		said = said,
		decision = current.decision,
		draft = if current.draft ~= "" then current.draft else none,
		task = if current.task ~= "" then current.task else none,
		workspace = tern.json.encode(current.workspace),
		context = if session then "" else prompts.render("chat", "context", { context = context(m, extras, matter.agent_thread(m)) }),
		format = prompts.render("chat", "format"),
	})
	omp.turn({ prompt = prompt, purpose = "chat", resume = session }, notice, function(text, next_session, cost, err, run)
		if err then
			done(nil, nil, next_session, cost, err, run)
			return
		end
		local output = omp.json_in(text or "")
		if not output then
			-- Plain words are still an answer; the judgment just stays as it is.
			done(text, {}, next_session, cost, nil, run)
			return
		end
		local reply, change, parse_error = judgment.change(output)
		done(reply, change, next_session, cost, parse_error, run)
	end)
end

-- Context is attached for a concrete information gap, not topic similarity.
function ai.task_prompt(m: Matter, task: string?, plan: context_plan.Plan, needs: context_plan.Answer?, evidence_array: { any }?): string
	assert(plan ~= "unknown", "未确定材料或讨论需求，不能启动任务")
	local header = stage.mark("task", prompts.render("task", "header"))
	local body = task or prompts.render("task", "open")
	if plan == "none" then
		return prompts.render("task", "none", { header = header, task = body })
	end
	local current_id = m.latest_id or m.id
	local referenced = task ~= nil and context_plan.has_locator(task, current_id)
	local material_required = plan == "message" or (needs ~= nil and needs.materials.choice == "required")
	local material_locators = {}
	local seen = { [current_id] = true }
	if task and material_required then
		for _, evidence in evidence_array or {} do
			if evidence.selected == true and evidence.status == "inspected" then
				local source_id = evidence.source_message_id
				if type(source_id) == "string" and not seen[source_id] then
					seen[source_id] = true
					if not context_plan.has_locator(task, source_id) then
						table.insert(material_locators, prompts.render("task", "material_locator", { message_id = source_id }))
					end
				end
			end
		end
	end
	local guidance = {}
	if not task then
		table.insert(guidance, prompts.render("task", "manual"))
	else
		if material_required then
			table.insert(guidance, prompts.render("task", "message"))
		end
		if plan == "conversation" then table.insert(guidance, prompts.render("task", "conversation")) end
	end
	return prompts.render("task", "attached", {
		header = header,
		guidance = table.concat(guidance, "\n"),
		task = body,
		chat = if m.chat_type == "p2p" then prompts.render("task", "p2p", { name = m.name }) else m.chat,
		chat_id = m.chat_id,
		locator = if referenced then prompts.render("task", "referenced") else prompts.render("task", "locator", { message_id = current_id }),
		material_locators = table.concat(material_locators, "\n"),
		time = m.time,
		now = os.date("%Y-%m-%d %H:%M") :: string,
		trigger = if referenced then "" else prompts.render("task", "trigger", {
			-- A message must not be able to close the block it is quoted in.
			content = (string.gsub(markup.clean(m.content), "</?feishu_messages>", "")),
		}),
	})
end

-- Judge the final confirmed task, not a cached analysis that may predate edits.
-- A fresh, disposable session cannot inherit unrelated triage context.
function ai.prepare_task(m: Matter, task: string?, notice: Notice, done: (string?, number, string?) -> ())
	if not task then
		done(ai.task_prompt(m, nil, "message"), 0, nil)
		return
	end
	local evidence_array = vision.describe(m, task)
	local total_cost = 0
	local function judge_needs(evidence: { any }, done_judging: (context_plan.Answer?, string?) -> ())
		local input = {
			state = {
				task = task,
				trigger = { message_id = m.latest_id or m.id, content = markup.clean(m.content) },
				thread = matter.agent_thread(m),
				evidence_array = evidence,
			},
			questions = {
				materials = {
					type = "choice", instructions = prompts.render("context", "materials"),
					criteria = {
						required = prompts.render("context", "materials_required"),
						not_required = prompts.render("context", "materials_not_required"),
						unknown = prompts.render("context", "materials_unknown"),
					},
				},
				discussion = {
					type = "choice", instructions = prompts.render("context", "discussion"),
					criteria = {
						required = prompts.render("context", "discussion_required"),
						not_required = prompts.render("context", "discussion_not_required"),
						unknown = prompts.render("context", "discussion_unknown"),
					},
				},
			},
		}
		local prompt = prompts.render("context", "turn", { input = tern.json.encode(input, true) })
		omp.turn({ prompt = prompt, purpose = "relevance", ephemeral = true }, notice, function(_text, _session, cost, err, run)
			total_cost += cost
			if err then done_judging(nil, err); return end
			local answer, parse_error = context_plan.parse(run and run.context_judgment)
			done_judging(answer, parse_error)
		end)
	end
	local function finish(answer: context_plan.Answer?, err: string?)
		if not answer then done(nil, total_cost, err or "未取得有效的材料与讨论需求判断"); return end
		local blocker = err or context_plan.blocker(answer, evidence_array)
		if blocker then done(nil, total_cost, blocker); return end
		done(ai.task_prompt(m, task, answer.plan, answer, evidence_array), total_cost, nil)
	end
	if context_plan.use_vision(evidence_array) then
		-- Selected screenshots go straight to the configured vision role: one
		-- turn observes pixels (or reuses facts) and decides both needs.
		vision.assess(m, task, notice, function(evidence, cost, needs, vision_error)
			evidence_array, total_cost = evidence, total_cost + cost
			local answer, parse_error = context_plan.from_vision(needs)
			finish(answer, vision_error or parse_error)
		end)
	else
		-- No task-selected pictures: typed questions through the judge role.
		judge_needs(evidence_array, finish)
	end
end

return ai

--!strict
-- Everything derived from one matter: its status, what `a` does, and the rules
-- that decide what may be edited, adjusted or started. The UI and the update
-- logic both ask here; nothing else interprets a matter's state.
local types = require("./types")

type Matter = types.Matter

local status = {}

-- Label and display tone for every status.
local LABELS: { [string]: { string } } = {
	queued = { "待分析", "muted" },
	manual = { "不交给 AI", "muted" },
	running = { "分析中", "info" },
	failed = { "分析失败", "warning" },
	deep = { "待执行", "muted" },
	reply = { "待回复", "muted" },
	fyi = { "可忽略", "muted" },
	snoozed = { "稍后", "muted" },
	handoff = { "待你发送", "accent" },
	task_starting = { "任务启动中", "muted" },
	task_working = { "任务执行中", "muted" },
	task_waiting = { "任务等你回复", "warning" },
	task_done = { "本轮结束 / 待确认", "warning" },
	task_closed = { "任务页已关闭", "warning" },
	archived = { "已归档", "muted" },
	replied = { "已回复", "muted" },
}
status.LABELS = LABELS

-- What a queue row shows as its state.
function status.of(m: Matter): string
	local d = m.disposition
	if d == "doing" then
		return "task_" .. (if m.task then m.task.phase else "closed")
	elseif d then
		return d
	end
	local a = m.analysis
	if a.phase == "done" then
		return if a.judgment then a.judgment.kind else "reply"
	elseif a.phase == "queued" and m.no_agent then
		return "manual"
	end
	return a.phase
end

-- Finished with: nothing about it changes any more.
function status.settled(m: Matter): boolean
	return m.disposition == "archived" or m.disposition == "replied"
end

function status.unread(m: Matter): boolean
	return m.is_read == false and not status.settled(m)
end

-- A task that needs you back: it asked something, finished, was closed, or the
-- chat went on after it started.
function status.task_needs_me(m: Matter): boolean
	local t = m.task
	if m.disposition ~= "doing" then
		return false
	end
	return t == nil or t.phase == "waiting" or t.phase == "done" or t.phase == "closed" or t.new_messages > 0
end

-- The judgment on screen predates messages that came in since: a new one is on its way.
function status.stale(m: Matter): boolean
	local a = m.analysis
	return a.judgment ~= nil and not a.judgment.manual and not m.no_agent
		and (a.phase == "queued" or a.phase == "running" or a.phase == "failed")
end

-- Shown in the queue as needing you: untriaged and not ignorable.
function status.pending(m: Matter): boolean
	return not m.hidden and m.disposition == nil and status.of(m) ~= "fyi"
end

-- The 待处理 view: pending matters and tasks waiting on you.
function status.needs_me(m: Matter): boolean
	return status.pending(m) or (not m.hidden and status.task_needs_me(m))
end

-- The `/` box talks to the analysis session, which can't reach a task in a tab.
function status.can_adjust(m: Matter): boolean
	return not status.settled(m) and m.disposition ~= "doing" and not status.stale(m)
end

-- The reply or task text can be edited.
function status.editable(m: Matter): boolean
	return m.analysis.judgment ~= nil and not status.settled(m) and m.disposition ~= "doing"
end

-- Editing can start: a matter without a judgment gets a blank one to write into.
function status.can_edit(m: Matter): boolean
	return not status.settled(m) and m.analysis.phase ~= "running" and m.disposition ~= "doing" and not status.stale(m)
end

function status.kind(m: Matter): types.Kind?
	local j = m.analysis.judgment
	return if j then j.kind else nil
end

function status.reply_text(m: Matter): string
	local j = m.analysis.judgment
	return m.edits.reply or (if j then j.draft else "")
end

function status.task_text(m: Matter): string
	local j = m.analysis.judgment
	return m.edits.task or (if j then j.task.prompt else "")
end

function status.task_workspace(m: Matter): string
	local j = m.analysis.judgment
	return m.edits.workspace or (if j then j.task.workspace else "")
end

-- What the editor shows: a deep matter's task, else its reply.
function status.field_text(m: Matter): string
	return if status.kind(m) == "deep" then status.task_text(m) else status.reply_text(m)
end

-- A hard-to-undo request only starts from the button, never from `a`.
function status.needs_confirm(m: Matter): boolean
	local j = m.analysis.judgment
	return not status.stale(m) and not status.settled(m) and m.disposition ~= "doing"
		and j ~= nil and j.kind == "deep" and (m.task_workspace_unconfirmed == true or string.find(j.risk, "%S") ~= nil)
end

export type Action = { key: string, label: string }

-- What `a` does, and what its button says.
function status.next_action(m: Matter): Action
	local s = status.of(m)
	if s == "task_done" then
		return { key = "jump", label = "回到任务继续" }
	elseif s == "task_closed" then
		return { key = "reopen", label = "重新开始任务" }
	elseif s == "task_waiting" then
		return { key = "jump", label = "去任务页回答" }
	elseif m.disposition == "doing" then
		return { key = "jump", label = "查看任务" }
	elseif m.preparing then
		return { key = "none", label = "准备任务…" }
	elseif s == "handoff" then
		return { key = "copy", label = "再次复制并去飞书" }
	elseif status.settled(m) then
		return { key = "none", label = status.LABELS[s][1] }
	end
	local j = m.analysis.judgment
	if not j then
		return { key = "none", label = "等待判断" }
	elseif status.stale(m) then
		return { key = "none", label = "等待新判断" }
	elseif j.kind == "deep" then
		return { key = "task", label = "开始任务" }
	elseif j.kind == "fyi" then
		return { key = "archive", label = "归档" }
	end
	return { key = "copy", label = if string.find(status.reply_text(m), "%S") then "复制并去回复" else "去飞书回复" }
end

-- How many messages a matter holds. A DM's folded ids can repeat across refreshes.
function status.message_count(m: Matter): number
	return if m.chat_type == "p2p" then 1 else 1 + #m.folded
end

-- Whether a message is one of those that put this matter in the queue.
function status.is_trigger(m: Matter, id: string): boolean
	return id == m.id or table.find(m.folded, id) ~= nil
end

-- Why a matter is back: you answered or closed it and the sender came back, or you
-- answered in Feishu during the burst, which shows in what was read of the chat.
function status.followup(m: Matter): string?
	if m.reopened then
		return m.reopened
	end
	if #m.folded == 0 or m.chat_type == "p2p" or m.disposition == "doing" then
		return nil
	end
	local triggers = 0
	for _, message in m.thread or {} do
		if status.is_trigger(m, message.id) then
			triggers += 1
		elseif message.mine and triggers > 0 and triggers < status.message_count(m) then
			return "你回复后有新消息"
		end
	end
	return nil
end

-- Every id the matter holds, for outcomes and read status.
function status.ids(m: Matter): { string }
	local ids = { m.id }
	for _, id in m.folded do
		table.insert(ids, id)
	end
	return ids
end

-- A blank judgment for writing a reply yourself.
function status.manual_judgment(): types.Judgment
	return {
		kind = "reply", pri = "P2", summary = "", why = "", draft = "", risk = "",
		task = { title = "", prompt = "", workspace = "" }, manual = true,
	}
end

return status

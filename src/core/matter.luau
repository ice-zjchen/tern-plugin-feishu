--!strict
-- Building matters from search results: one per message, a sender's run of
-- mentions folded into one, a DM chat as one, and the rules that hide a matter
-- or keep it from AI.
local types = require("./types")
local status = require("./status")
local time = require("../shared/time")
local markup = require("../shared/markup")

type Matter = types.Matter
type Model = types.Model

local matter = {}

-- Consecutive mentions from one sender in one group are one matter: within this gap
-- while it is still open, and within the longer one once you answered or closed it.
local BURST_SECONDS = 10 * 60
local REPLY_BACK_SECONDS = 30 * 60
-- A chat that is still moving gets a moment to finish before AI reads it.
matter.SETTLE_SECONDS = 90

function matter.log(model: Model, who: string, text: string)
	table.insert(model.log, 1, { t = os.date("%H:%M", model.cfg.now) :: string, who = who, text = text })
	while #model.log > 100 do
		table.remove(model.log)
	end
end

function matter.find(model: Model, id: string?): Matter?
	if not id then
		return nil
	end
	for _, m in model.items do
		if m.id == id then
			return m
		end
	end
	return nil
end

local function settle_at(m: Matter, now: number): number
	return (time.parse(m.time) or now) + matter.SETTLE_SECONDS
end

-- A new matter from one search result.
function matter.make(message: any, now: number): Matter
	local from = if type(message.sender) == "table" then message.sender else {}
	local p2p = message.chat_type == "p2p"
	local name = tostring(from.name or from.id or "未知发送者")
	local m: Matter = {
		id = message.message_id,
		revision = 0,
		chat_id = tostring(message.chat_id or ""),
		chat = if p2p then name else tostring(message.chat_name or message.chat_id or "未知会话"),
		chat_type = tostring(message.chat_type or "group"),
		name = name,
		sender_id = tostring(from.id or ""),
		sender_type = if from.sender_type == "bot" or from.sender_type == "app" then "bot"
			elseif from.sender_type == "user" then "user" else "unknown",
		time = tostring(message.create_time or ""),
		content = tostring(message.content or "[无正文]"),
		deleted = message.deleted == true,
		link = if type(message.message_app_link) == "string" then message.message_app_link else nil,
		mention = false,
		via = if p2p then "私聊" else "群聊",
		folded = {},
		analysis = {
			phase = "queued", gen = 0, backlog = false, force = false, reanalyze = false,
		},
		edits = {},
		talk = {},
		hidden = false,
		no_agent = false,
	}
	m.analysis.settle_at = settle_at(m, now)
	return m
end

-- Applies sources, bots, mute preferences, keywords and chat rules: `hidden`
-- removes a matter from every view, `no_agent` keeps it visible but away from AI.
function matter.apply_rules(model: Model)
	local cfg = model.cfg
	local s = cfg.settings
	local words = {}
	for word in string.gmatch(s.ignore_keywords or "", "[^,，%s]+") do
		table.insert(words, string.lower(word))
	end
	local stars: { [string]: boolean } = {}
	for _, star in cfg.stars do
		stars[star.id] = true
	end
	for _, m in model.items do
		local rule = cfg.rules[m.chat_id]
		local at_all = m.via == "@所有人"
		local wanted = (m.mention and not at_all and s.source_mention)
			or (at_all and not s.hide_atall)
			or (m.chat_type == "p2p" and s.source_dm)
			or (stars[m.sender_id] and s.source_star)
		local hidden = not wanted or (at_all and s.hide_atall) or (rule ~= nil and rule.mode == "hide")
			or (m.sender_type == "bot" and s.hide_bots)
		if s.hide_muted and m.chat_type ~= "p2p" then
			local pref = model.chat_settings and model.chat_settings[m.chat_id]
			-- A chat whose setting could not be read stays hidden rather than slip through.
			hidden = hidden or not pref or pref.is_muted or (at_all and pref.is_mute_at_all)
		end
		if not hidden then
			local name = string.lower(m.chat)
			for _, word in words do
				hidden = hidden or string.find(name, word, 1, true) ~= nil
			end
		end
		m.hidden = hidden == true
		m.no_agent = not m.analysis.force and (not s.agent_enabled or (rule ~= nil and rule.mode == "manual"))
	end
end

-- Only a sender's direct mentions in a group chain together. @所有人 is an announcement.
local function chains(m: Matter): boolean
	return m.chat_type ~= "p2p" and m.via == "@我" and m.sender_id ~= "" and not m.deleted
end

local function chain_key(m: Matter): string
	return m.chat_id .. "\0" .. m.sender_id
end

-- Whether a newly found message continues `head`'s matter. Restored outcomes only
-- rebuild a chain that had the same outcome; they never change it.
local function continues(head: Matter, m: Matter): boolean
	if m.disposition and m.disposition ~= head.disposition then
		return false
	end
	local from, to = time.parse(head.time), time.parse(m.time)
	if not from or not to then
		return false
	end
	local open = head.disposition == nil or head.disposition == "snoozed"
	return math.abs(to - from) <= (if open then BURST_SECONDS else REPLY_BACK_SECONDS)
end

export type Effect = { [string]: any }

-- Folds a new message into its matter, which keeps its id: tasks, sessions and
-- outcomes hang off it. The judgment no longer covers everything that was said,
-- so the matter comes back to you and goes round again.
local function absorb(model: Model, head: Matter, m: Matter, out: { Effect })
	table.insert(head.folded, m.id)
	if m.time < head.time then
		-- Found by looking further back: nothing new has happened in this matter.
		return
	end
	head.latest_id, head.content, head.time, head.link, head.deleted = m.id, m.content, m.time, m.link, m.deleted
	head.revision += 1
	head.thread, head.thread_error = nil, nil
	if m.disposition then
		return
	end
	local was = head.disposition
	if was == "doing" then
		-- Third-party words never go into a running task by themselves.
		if head.task then
			head.task.new_messages += 1
		end
		matter.log(model, "agent", m.name .. "：任务执行中又有新消息")
		return
	end
	if was then
		head.reopened = if was == "archived" then "归档后有新消息" elseif was == "snoozed" then nil else "你回复后有新消息"
		head.disposition, head.spoken, head.handoff_at = nil, nil, nil
		head.analysis.backlog = false
		table.insert(out, { type = "record", ids = status.ids(head), outcome = nil } :: Effect)
		if model.undo and model.undo.id == head.id then
			model.undo = nil
		end
		model.flash = m.name .. " 又 @ 了你，已放回待处理"
		matter.log(model, "agent", model.flash :: string)
	end
	local a = head.analysis
	if a.phase == "running" then
		a.reanalyze = true
	elseif not (a.judgment and a.judgment.manual) then
		a.phase, a.error = "queued", nil
		a.settle_at = settle_at(m, model.cfg.now)
	end
end

export type Source = { messages: { any }, mention: boolean }

-- Merges search results into the queue: new matters, folded mentions, a DM chat's
-- newest message replacing its older ones, outcomes restored from `decided`.
function matter.merge(model: Model, sources: { Source }, decided: { [string]: any }, out: { Effect })
	local now = model.cfg.now
	local known: { [string]: Matter } = {}
	local absorbed: { [string]: boolean } = {}
	local heads: { [string]: Matter } = {}
	for _, m in model.items do
		known[m.id] = m
		if m.chat_type ~= "p2p" then
			for _, id in m.folded do
				absorbed[id] = true
			end
		end
		if chains(m) then
			local key = chain_key(m)
			if not heads[key] or m.time > heads[key].time then
				heads[key] = m
			end
		end
	end
	-- Oldest first, so a chat's newer message folds the older ones in.
	local entries: { any }, seen: { [string]: any } = {}, {}
	for _, source in sources do
		for _, message in source.messages do
			if type(message) == "table" and type(message.message_id) == "string" then
				local sender = if type(message.sender) == "table" then message.sender.id else nil
				if sender ~= model.me then
					local entry = seen[message.message_id]
					if not entry then
						entry = { message = message, mention = false }
						seen[message.message_id] = entry
						table.insert(entries, entry)
					end
					entry.mention = entry.mention or source.mention
				end
			end
		end
	end
	table.sort(entries, function(a: any, b: any): boolean
		local ta, tb = tostring(a.message.create_time or ""), tostring(b.message.create_time or "")
		if ta ~= tb then
			return ta < tb
		end
		return a.message.message_id < b.message.message_id
	end)
	local superseded: { [Matter]: boolean } = {}
	local chats: { [string]: Matter } = {}
	for _, entry in entries do
		local id = entry.message.message_id
		if absorbed[id] then
			continue
		end
		local m = known[id]
		local created = m == nil
		if not m then
			m = matter.make(entry.message, now)
			known[id] = m
			table.insert(model.items, m)
			local decision = decided[id]
			if type(decision) == "table" and type(decision.s) == "string" then
				m.disposition = decision.s
				m.handoff_at = if decision.s == "handoff" then decision.t else nil
			end
		end
		local it = m :: Matter
		if id == (it.latest_id or it.id) then
			it.deleted = entry.message.deleted == true
		end
		local mentions_me = false
		for _, mention in (if type(entry.message.mentions) == "table" then entry.message.mentions else {}) do
			mentions_me = mentions_me or (type(mention) == "table" and mention.id == model.me)
		end
		if entry.mention then
			it.mention = true
			it.via = if mentions_me then "@我" else "@所有人"
		elseif it.via == "群聊" and not mentions_me and markup.mentions_all(it.content) then
			-- Found through another source, such as a starred sender's message.
			it.via = "@所有人"
		end
		if created and chains(it) then
			local key = chain_key(it)
			local head = heads[key]
			if head and head ~= it and continues(head, it) then
				absorb(model, head, it, out)
				superseded[it] = true
			else
				heads[key] = it
			end
		end
		if it.chat_type == "p2p" and it.disposition == nil then
			local older = chats[it.chat_id]
			if older then
				local seen_ids = { [it.id] = true }
				for _, folded_id in it.folded do seen_ids[folded_id] = true end
				for _, folded in status.ids(older) do
					if not seen_ids[folded] then
						seen_ids[folded] = true
						table.insert(it.folded, folded)
					end
				end
				superseded[older] = true
			end
			chats[it.chat_id] = it
		end
	end
	local kept = {}
	local stars: { [string]: boolean } = {}
	for _, star in model.cfg.stars do
		stars[star.id] = true
	end
	for _, m in model.items do
		if not superseded[m] then
			table.insert(kept, m)
			if stars[m.sender_id] and (m.via == "私聊" or m.via == "群聊") then
				m.via = "★ " .. m.via
			end
			if m.deleted and m.analysis.phase == "queued" then
				m.analysis.phase = "done"
				m.analysis.judgment = {
					kind = "fyi", pri = "P3", summary = "这条消息已撤回。", why = "", draft = "", risk = "",
					task = { title = "", prompt = "" }, manual = false,
				}
			end
		end
	end
	model.items = kept
	matter.apply_rules(model)
end

-- The thread as AI sees it: images replaced by marks.
function matter.agent_thread(m: Matter): { any }
	local out = {}
	for _, message in m.thread or {} do
		table.insert(out, { id = message.id, sender = message.sender, time = message.time, content = markup.clean(message.content) })
	end
	return out
end

return matter

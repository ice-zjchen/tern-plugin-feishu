-- The workbench: a queue of Feishu messages omp has judged ahead of you. Each one
-- is to ignore, to reply to, or to work on, and `a` does whichever it is: archive,
-- copy the reply and go to Feishu, or open a new omp tab. You send every reply
-- yourself, and a tab only opens when you ask for it.
--
-- Messages, judgments, drafts and analysis-session ids are checkpointed locally.
-- Reload restores the queue without refetching or replaying interrupted turns.

local tern = require("tern")
local edit = require("./edit")
local feishu = require("./feishu")
local agent = require("./agent")
local runtime = require("./runtime")
local settings = require("./settings")
local view = require("./view")
local cache = require("./cache")

local DECISION_TTL = 30 * 86400
local MAX_IMAGE_BYTES = 20 * 1024 * 1024

local VIEWS = {
	{ id = "pending", label = "需要我" },
	{ id = "doing", label = "处理中" },
	{ id = "later", label = "稍后" },
	{ id = "done", label = "已处理" },
	{ id = "fyi", label = "可忽略" },
	{ id = "mention", label = "@我" },
	{ id = "dm", label = "私聊" },
}

local TASK_POLL_MS = 3000

-- Consecutive mentions from one sender in one group are one matter: within this gap
-- while it is still open, and within the longer one once you have answered or closed it.
local BURST_SECONDS = 10 * 60
local REPLY_BACK_SECONDS = 30 * 60
-- A chat that is still moving gets a moment to finish before omp reads it.
local SETTLE_SECONDS = 90
local TASK_LINK = "tern-plugin-feishu://task/"


local running: { [number]: any } = {}

local function alive(state: any): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, pane in tern.pane.list() do
		if pane.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	if state.poll then
		state.poll:cancel()
	end
	return false
end

local function clock(): string
	return os.date("%H:%M") :: string
end

local function log(state: any, who: string, text: string)
	table.insert(state.log, 1, { t = clock(), who = who, text = text })
	while #state.log > 100 do
		table.remove(state.log)
	end
end

local function render(state: any)
	cache.save(state)
	state.cx:render()
end

----------------------------------------------------------------------------
-- Persisted decisions and stars

local function decisions(): { [string]: any }
	local stored = tern.kv.get("decisions")
	return if type(stored) == "table" then stored else {}
end

local function record(ids: { string }, outcome: string?)
	local stored = decisions()
	local now = os.time()
	for id, decision in stored do
		if type(decision) ~= "table" or now - (tonumber(decision.t) or 0) > DECISION_TTL then
			stored[id] = nil
		end
	end
	for _, id in ids do
		stored[id] = if outcome then { s = outcome, t = now } else nil
	end
	tern.kv.set("decisions", stored)
end

local function stars(): { any }
	local stored = tern.kv.get("stars")
	return if type(stored) == "table" then stored else {}
end

local function is_star(id: string): boolean
	for _, star in stars() do
		if star.id == id then
			return true
		end
	end
	return false
end

local function all_ids(item: any): { string }
	local ids = { item.id }
	for _, id in item.folded do
		table.insert(ids, id)
	end
	return ids
end

-- Applies sources, bots, notification preferences, keywords and chat rules.
-- `hidden` removes a message; `no_agent` keeps it visible but away from omp.
local function apply_rules(state: any)
	local rules = settings.rules()
	local keywords = settings.keywords()
	local paused = not settings.get("agent_enabled")
	for _, item in state.items do
		local rule = rules[item.chat_id]
		local star = is_star(item.sender_id)
		local at_all = item.via == "@所有人"
		local hide_atall = settings.get("hide_atall")
		local wanted = (item.mention and not at_all and settings.get("source_mention"))
			or (at_all and not hide_atall)
			or (item.chat_type == "p2p" and settings.get("source_dm"))
			or (star and settings.get("source_star"))
		local hidden = not wanted or (at_all and hide_atall) or (rule and rule.mode == "hide") or (item.sender_type == "bot" and settings.get("hide_bots"))
		if settings.get("hide_muted") and item.chat_type ~= "p2p" then
			local pref = state.chat_settings and state.chat_settings[item.chat_id]
			hidden = hidden or not pref or pref.is_muted or (item.via == "@所有人" and pref.is_mute_at_all)
		end
		if not hidden then
			local name = string.lower(item.chat)
			for _, word in keywords do
				hidden = hidden or string.find(name, word, 1, true) ~= nil
			end
		end
		item.hidden = hidden == true
		item.no_agent = not item.force and (paused or (rule ~= nil and rule.mode == "manual"))
	end
end

----------------------------------------------------------------------------
-- Which items each view shows

local function pending(item: any): boolean
	if item.triage or item.hidden then
		return false
	end
	return view.status(item) ~= "fyi"
end

-- What the "needs me" view holds: untriaged messages, and omp tabs waiting on you.
local function needs_me(item: any): boolean
	return pending(item) or (not item.hidden and view.task_needs_me(item))
end

local function shows(state: any, item: any): boolean
	if item.hidden then
		return false
	end
	if state.source == "mention" and not item.mention then
		return false
	elseif state.source == "dm" and item.chat_type ~= "p2p" then
		return false
	end
	if state.person then
		return item.sender_id == state.person and needs_me(item)
	end
	local v = state.view
	if v == "pending" then
		return needs_me(item)
	elseif v == "mention" then
		return needs_me(item) and item.mention
	elseif v == "doing" then
		return item.triage == "handoff" or (item.triage == "doing" and not view.task_needs_me(item))
	elseif v == "dm" then
		return needs_me(item) and item.chat_type == "p2p"
	elseif v == "fyi" then
		return not item.triage and view.status(item) == "fyi"
	elseif v == "later" then
		return item.triage == "snoozed"
	end
	return item.triage == "sent" or item.triage == "archived" or item.triage == "replied"
end

-- Queue order: omp waiting on you, then what to work on, what to answer, the rest.
local function group(item: any): number
	local status = view.status(item)
	return if view.task_needs_me(item) then 0 elseif status == "deep" then 1 elseif status == "reply" then 2 else 3
end

local function rank(item: any): number
	return if item.analysis then tonumber(string.sub(item.analysis.pri, 2)) :: number else 1.5
end

local function visible(state: any): { any }
	local shown = {}
	for _, item in state.items do
		if shows(state, item) then
			table.insert(shown, item)
		end
	end
	table.sort(shown, function(a, b)
		local ga, gb = group(a), group(b)
		if ga ~= gb then
			return ga < gb
		end
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then
			return ra < rb
		end
		local ua, ub = view.unread(a), view.unread(b)
		if ua ~= ub then
			return ua
		end
		if a.time ~= b.time then
			return a.time > b.time
		end
		return a.id < b.id
	end)
	return shown
end

local function by_id(state: any, id: string?): any
	for _, item in state.items do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function current(state: any): any
	return by_id(state, state.selected)
end

local function draft_text(item: any): string
	return item.edited or (item.analysis and item.analysis.draft) or ""
end

local function task_text(item: any): string
	return item.task_edited or (item.analysis and item.analysis.task.prompt) or ""
end

-- The text the detail pane is showing for editing: a deep item's is its task.
local function field_text(item: any): string
	return if item.analysis and item.analysis.state == "deep" then task_text(item) else draft_text(item)
end

-- Keeps a selection in the visible queue, nearest to where it was.
local function reselect(state: any, near: number?)
	local shown = visible(state)
	for _, item in shown do
		if item.id == state.selected then
			return
		end
	end
	local next_item = shown[math.clamp(near or 1, 1, math.max(1, #shown))]
	state.selected = next_item and next_item.id
	state.draft_cursor = edit.len(next_item and field_text(next_item) or "")
end

local function index_in(shown: { any }, id: string?): number
	for i, item in shown do
		if item.id == id then
			return i
		end
	end
	return 1
end

----------------------------------------------------------------------------
-- The agent pipeline: thread, images, then analysis, a few at a time

local pump: (state: any) -> ()
local schedule_settled: (state: any) -> ()

local function mime_of(bytes: string): string
	local head = string.sub(bytes, 1, 12)
	if string.sub(head, 1, 4) == "\137PNG" then
		return "image/png"
	elseif string.sub(head, 1, 3) == "GIF" then
		return "image/gif"
	elseif string.sub(head, 1, 4) == "RIFF" and string.sub(head, 9, 12) == "WEBP" then
		return "image/webp"
	end
	return "image/jpeg"
end

-- Downloads an image once; `done` runs when it is there or has failed.
local function get_image(state: any, message_id: string, key: string, done: (any) -> ())
	local image = state.images[key]
	if image and image.settled then
		done(image)
		return
	elseif image then
		table.insert(image.waiters, done)
		return
	end
	local cached_path = state.image_paths and state.image_paths[key]
	if cached_path then
		local ok, bytes = pcall(tern.fs.read, tern.plugin.data .. "/" .. cached_path, MAX_IMAGE_BYTES)
		if ok then
			image = { path = cached_path, settled = true, blob = state.cx:blob(bytes, mime_of(bytes)) }
			state.images[key] = image
			done(image)
			return
		end
	end
	image = { waiters = { done } }
	state.images[key] = image
	feishu.download_image(message_id, key, function(path, err)
		image.settled = true
		if path then
			local ok, bytes = pcall(tern.fs.read, tern.plugin.data .. "/" .. path, MAX_IMAGE_BYTES)
			if ok then
				image.path = path
				image.blob = state.cx:blob(bytes, mime_of(bytes))
			end
		end
		image.failed = not image.blob
		image.error = err
		for _, waiter in image.waiters do
			waiter(image)
		end
		image.waiters = {}
		if alive(state) then
			render(state)
		end
	end)
end

local function show_images_of(state: any, message: any)
	if settings.get("show_images") and not message.deleted then
		for _, key in feishu.images_in(message.content, 4) do
			get_image(state, message.id, key, function() end)
		end
	end
end

-- Reads a message's chat once. A DM has one item per chat, on its latest message:
-- read what is newest to see whether you already answered. Elsewhere, read up to
-- the mention.
local function load_thread(state: any, item: any, done: () -> ())
	if item.thread then
		for _, message in item.thread do
			show_images_of(state, message)
		end
		done()
		return
	elseif item.thread_waiters then
		table.insert(item.thread_waiters, done)
		return
	end
	item.thread_waiters = { done }
	local until_time = if item.chat_type == "p2p" then nil else item.time
	feishu.history(item.chat_id, settings.get("thread_size"), until_time, function(messages, err)
		local waiters = item.thread_waiters
		item.thread_waiters = nil
		item.thread_error = err
		local thread, seen = {}, false
		for _, message in messages or {} do
			if type(message) == "table" and type(message.message_id) == "string" then
				local from = message.sender
				local mine = type(from) == "table" and from.id == state.me
				table.insert(thread, {
					id = message.message_id,
					sender = if mine then "我" elseif type(from) == "table" then tostring(from.name or from.id or "?") else "?",
					time = tostring(message.create_time or ""),
					content = tostring(message.content or ""),
					deleted = message.deleted == true,
					mine = mine,
				})
				seen = seen or message.message_id == (item.latest_id or item.id)
			end
		end
		if not seen then
			table.insert(thread, { id = item.latest_id or item.id, sender = item.name, time = item.time, content = item.content, deleted = item.deleted })
		end
		item.thread = thread
		item.thread_for_agent = {}
		for _, message in thread do
			table.insert(item.thread_for_agent, { id = message.id, sender = message.sender, time = message.time, content = feishu.clean(message.content) })
		end
		local last = thread[#thread]
		if messages and item.chat_type == "p2p" and last and last.mine and not item.triage then
			item.triage = "replied"
			log(state, "agent", item.name .. "：你已在飞书回复，移到已处理")
		end
		if alive(state) then
			for _, message in thread do
				show_images_of(state, message)
			end
			reselect(state, nil)
			for _, waiter in waiters do
				waiter()
			end
			render(state)
		end
	end)
end

local function extras(state: any, except: any): any
	local others = {}
	for _, item in state.items do
		-- A chat you keep from the agent stays out of other messages' context too.
		if item ~= except and pending(item) and not item.no_agent and #others < 12 then
			table.insert(others, {
				sender = item.name,
				chat = item.chat,
				summary = if item.analysis then item.analysis.summary else string.sub(feishu.clean(item.content), 1, 200),
			})
		end
	end
	return {
		notice = function(warning: string?)
			if state.runtime_warning ~= warning then
				state.runtime_warning = warning
				if warning then
					log(state, "omp", warning)
				end
				render(state)
			end
		end,
		others = others,
		agenda = if settings.get("use_agenda") then state.agenda else nil,
		clean = feishu.clean,
	}
end

local function analyze(state: any, item: any, images: { string })
	local read = item.thread_for_agent
	local through = if read and #read > 0 then read[#read].id else nil
	local had_session = item.session ~= nil
	agent.analyze(item, extras(state, item), images, function(analysis, session, cost, err, run)
		state.spent += cost
		state.active -= 1
		item.session = session or item.session
		item.run = run or item.run
		if not alive(state) then
			return
		end
		if err then
			item.agent, item.agent_error = "failed", err
			-- A session that can't be resumed must not fail every retry too.
			item.session = if had_session then nil else item.session
			log(state, "agent", item.name .. "：分析失败")
		else
			item.agent, item.analysis, item.edited, item.task_edited, item.agent_error = "done", analysis, nil, nil, nil
			item.analyzed_through = through
			if item.id == state.selected then
				state.draft_cursor = edit.len(field_text(item))
			end
			local verdict = view.STATUS[analysis.state][1]
			log(state, "agent", item.name .. "：标记为 " .. analysis.pri .. "，" .. verdict)
		end
		if item.reanalyze then
			-- More messages came in during this turn; it didn't see them.
			item.reanalyze = nil
			item.agent, item.thread, item.thread_for_agent = "queued", nil, nil
		end
		schedule_settled(state)
		pump(state)
		render(state)
	end)
end

local function start(state: any, item: any)
	item.agent, item.agent_error = "running", nil
	state.active += 1
	log(state, "agent", item.name .. "：开始分析")
	cache.save(state)
	load_thread(state, item, function()
		if not alive(state) then
			state.active -= 1
			return
		end
		if item.triage == "replied" then
			item.agent = "done"
			state.active -= 1
			pump(state)
			return
		end
		local keys = if settings.get("agent_images") then feishu.images_in(item.content, 3) else {}
		local image_message = item.latest_id or item.id
		local waiting, paths = #keys, {}
		if waiting == 0 then
			analyze(state, item, paths)
			return
		end
		for _, key in keys do
			get_image(state, image_message, key, function(image)
				if image.path then
					table.insert(paths, image.path)
				end
				waiting -= 1
				if waiting == 0 then
					analyze(state, item, paths)
				end
			end)
		end
	end)
end

local function settled(item: any): boolean
	return not item.settle_at or item.settle_at <= os.time()
end

-- Wakes the queue when the next waiting chat has had its moment.
schedule_settled = function(state: any)
	local soonest: number? = nil
	for _, item in state.items do
		if item.agent == "queued" and item.settle_at and not settled(item) then
			soonest = math.min(soonest or item.settle_at, item.settle_at)
		end
	end
	if not soonest or state.settle_timer_at == soonest then
		return
	end
	state.settle_timer_at = soonest
	tern.timer(math.max(1, soonest - os.time() + 1) * 1000, function()
		if state.settle_timer_at == soonest then
			state.settle_timer_at = nil
		end
		if alive(state) then
			schedule_settled(state)
			pump(state)
			render(state)
		end
	end)
end

pump = function(state: any)
	while state.active < settings.get("concurrency") do
		local chosen = current(state)
		if not (chosen and chosen.agent == "queued" and not chosen.no_agent and settled(chosen) and (not chosen.triage or chosen.triage == "snoozed")) then
			chosen = nil
			for _, item in visible({ items = state.items, view = "pending" }) do
				if item.agent == "queued" and not item.triage and not item.no_agent and not item.backlog and settled(item) then
					chosen = item
					break
				end
			end
		end
		if not chosen then
			return
		end
		start(state, chosen)
	end
end

----------------------------------------------------------------------------
-- Retrieval

local function make_item(message: any): any
	local from = if type(message.sender) == "table" then message.sender else {}
	local p2p = message.chat_type == "p2p"
	local name = tostring(from.name or from.id or "未知发送者")
	return {
		id = message.message_id,
		chat_id = tostring(message.chat_id or ""),
		chat = if p2p then name else tostring(message.chat_name or message.chat_id or "未知会话"),
		chat_type = tostring(message.chat_type or "group"),
		name = name,
		sender_id = tostring(from.id or ""),
		time = tostring(message.create_time or ""),
		content = tostring(message.content or "[无正文]"),
		deleted = message.deleted == true,
		link = message.message_app_link,
		sender_type = if from.sender_type == "bot" or from.sender_type == "app" then "bot"
			elseif from.sender_type == "user" then "user" else "unknown",
		mention = false,
		via = if p2p then "私聊" else "群聊",
		folded = {},
		agent = "queued",
	}
end

local function seconds_of(time: string): number?
	local y, mo, d, h, mi, s = string.match(time, "^(%d+)-(%d+)-(%d+) (%d+):(%d+):?(%d*)")
	if not y then
		return nil
	end
	return os.time({
		year = tonumber(y) :: number, month = tonumber(mo) :: number, day = tonumber(d) :: number,
		hour = tonumber(h) :: number, min = tonumber(mi) :: number, sec = tonumber(s) or 0,
	})
end

-- Only a sender's direct mentions in a group chain together. @所有人 is an announcement.
local function chains(item: any): boolean
	return item.chat_type ~= "p2p" and item.via == "@我" and item.sender_id ~= "" and not item.deleted
end

local function chain_key(item: any): string
	return item.chat_id .. "\0" .. item.sender_id
end

-- Whether a newly found message continues `head`'s matter. Decisions restored for it
-- only rebuild a chain that had the same outcome; they never change the outcome.
local function continues(head: any, item: any): boolean
	if item.triage and item.triage ~= head.triage then
		return false
	end
	local from, to = seconds_of(head.time), seconds_of(item.time)
	if not from or not to then
		return false
	end
	local open = not head.triage or head.triage == "snoozed"
	return math.abs(to - from) <= (if open then BURST_SECONDS else REPLY_BACK_SECONDS)
end

-- Folds a new message into its matter, which keeps its id: tasks, sessions and
-- decisions hang off it. The judgment it had no longer covers everything that was
-- said, so the matter comes back to you and goes round again.
local function absorb(state: any, head: any, item: any)
	table.insert(head.folded, item.id)
	if item.time < head.time then
		-- Found by looking further back: nothing new has happened in this matter.
		return
	end
	head.latest_id, head.content, head.time, head.link, head.deleted = item.id, item.content, item.time, item.link, item.deleted
	head.thread, head.thread_for_agent, head.thread_error = nil, nil, nil
	if item.triage then
		return
	end
	local was = head.triage
	if was == "doing" then
		-- Third-party words never go into a running task by themselves.
		head.task_new = (head.task_new or 0) + 1
		log(state, "agent", item.name .. "：omp 处理中又有新消息")
		return
	end
	if was then
		head.reopened = if was == "archived" then "归档后有新消息" elseif was == "snoozed" then nil else "你回复后有新消息"
		head.triage, head.spoken, head.handoff_at, head.backlog = nil, nil, nil, false
		record(all_ids(head), nil)
		if state.undo and state.undo.id == head.id then
			state.undo = nil
		end
		state.flash = item.name .. " 又 @ 了你，已放回需要我"
		log(state, "agent", state.flash)
	end
	if head.agent == "running" then
		head.reanalyze = true
	elseif not (head.analysis and head.analysis.manual) then
		head.agent, head.agent_error = "queued", nil
		head.settle_at = (seconds_of(item.time) or os.time()) + SETTLE_SECONDS
	end
end

local function merge(state: any, sources: { any })
	local known: { [string]: any } = {}
	local absorbed: { [string]: boolean } = {}
	local heads: { [string]: any } = {}
	for _, item in state.items do
		known[item.id] = item
		if item.chat_type ~= "p2p" then
			for _, id in item.folded do
				absorbed[id] = true
			end
		end
		if chains(item) then
			local key = chain_key(item)
			if not heads[key] or item.time > heads[key].time then
				heads[key] = item
			end
		end
	end
	local decided = decisions()
	-- Oldest first, so a chat's newer message folds the older ones in.
	local messages, seen = {}, {}
	for _, source in sources do
		for _, message in source.messages do
			if type(message) == "table" and type(message.message_id) == "string" then
				local sender = if type(message.sender) == "table" then message.sender.id else nil
				if sender ~= state.me then
					local entry = seen[message.message_id]
					if not entry then
						entry = { message = message, mention = false }
						seen[message.message_id] = entry
						table.insert(messages, entry)
					end
					entry.mention = entry.mention or source.mention
				end
			end
		end
	end
	table.sort(messages, function(a, b)
		local ta, tb = tostring(a.message.create_time or ""), tostring(b.message.create_time or "")
		if ta ~= tb then
			return ta < tb
		end
		return a.message.message_id < b.message.message_id
	end)
	local chats: { [string]: any } = {}
	for _, entry in messages do
		local id = entry.message.message_id
		if absorbed[id] then
			continue
		end
		local item = known[id]
		local created = not item
		if not item then
			item = make_item(entry.message)
			item.settle_at = (seconds_of(item.time) or os.time()) + SETTLE_SECONDS
			known[id] = item
			table.insert(state.items, item)
			local decision = decided[id]
			if type(decision) == "table" then
				item.triage = decision.s
				item.handoff_at = if decision.s == "handoff" then decision.t else nil
			end
		end
		if id == (item.latest_id or item.id) then
			item.deleted = entry.message.deleted == true
		end
		local mentions_me = false
		for _, m in (if type(entry.message.mentions) == "table" then entry.message.mentions else {}) do
			mentions_me = mentions_me or (type(m) == "table" and m.id == state.me)
		end
		if entry.mention then
			item.mention = true
			item.via = if mentions_me then "@我" else "@所有人"
		elseif item.via == "群聊" and not mentions_me and feishu.mentions_all(item.content) then
			-- Found through another source, such as a starred sender's message.
			item.via = "@所有人"
		end
		if created and chains(item) then
			local key = chain_key(item)
			local head = heads[key]
			if head and head ~= item and continues(head, item) then
				absorb(state, head, item)
				item.superseded = true
			else
				heads[key] = item
			end
		end
		if item.chat_type == "p2p" and not item.triage then
			local older = chats[item.chat_id]
			if older then
				for _, folded in all_ids(older) do
					table.insert(item.folded, folded)
				end
				older.superseded = true
			end
			chats[item.chat_id] = item
		end
	end
	local kept = {}
	for _, item in state.items do
		if not item.superseded then
			table.insert(kept, item)
		end
	end
	state.items = kept
	for _, item in state.items do
		if is_star(item.sender_id) and item.via == "私聊" then
			item.via = "★ 私聊"
		elseif is_star(item.sender_id) and item.via == "群聊" then
			item.via = "★ 群聊"
		end
		if item.deleted and item.agent == "queued" then
			item.agent = "done"
			item.analysis = {
				pri = "P3", state = "fyi", summary = "这条消息已撤回。", why = "", draft = "", task = { title = "", prompt = "" },
			}
		end
	end
	apply_rules(state)
	schedule_settled(state)
end

-- Removes what a settled message left on disk, unless `u` could still reopen it.
local function prune(state: any)
	for _, item in state.items do
		if view.settled(item) and not (state.undo and state.undo.id == item.id) then
			if item.session then
				agent.forget(item.session)
				item.session = nil
			end
			if runtime.task(item.id) then
				runtime.set_task(item.id, nil)
			end
		end
	end
end

-- Feishu's read state, re-read on every refresh for what is still open. It only
-- orders and marks the queue; reading a message in Feishu never settles it here.
-- `is_read` stays nil when Feishu can't say, which doesn't count as read.
local function sync_read(state: any, done: () -> ())
	local open, ids = {}, {}
	for _, item in state.items do
		if not item.hidden and not view.settled(item) then
			table.insert(open, item)
			for _, id in all_ids(item) do
				table.insert(ids, id)
			end
		end
	end
	if #ids == 0 then
		done()
		return
	end
	feishu.read_status(ids, function(found, err)
		if not alive(state) then
			return
		end
		if err then
			local problem = "已读状态：" .. err
			state.problem = if state.problem then state.problem .. "\n" .. problem else problem
		end
		for _, item in open do
			local is_read: boolean? = true
			for _, id in all_ids(item) do
				if found[id] == false then
					is_read = false
					break
				elseif found[id] == nil then
					is_read = nil
				end
			end
			item.is_read = is_read
		end
		done()
	end)
end

-- Whether you have spoken in the chat of a reply you took to Feishu. Any message of
-- yours after the handoff counts, so the row names it and `u` can take it back.
local function sync_replies(state: any)
	for _, item in state.items do
		if item.triage == "handoff" and state.me then
			local since = os.date("%Y-%m-%d %H:%M", item.handoff_at or os.time()) :: string
			feishu.search({ "--chat-id", item.chat_id, "--sender", state.me }, 1, function(data, err)
				if err or not alive(state) or item.triage ~= "handoff" then
					return
				end
				for _, message in data.messages do
					if type(message) == "table" and not message.deleted and tostring(message.create_time or "") >= since then
						local spoken = feishu.clean(tostring(message.content or ""))
						if item.spoken ~= spoken then
							item.spoken = spoken
							state.flash = "检测到可能的回复，请确认：" .. spoken
							log(state, "你", "可能已回复 " .. item.name .. "：" .. spoken)
							render(state)
						end
						break
					end
				end
			end)
		end
	end
end

-- Takes up what the window half recorded about each omp tab. A finished task that
-- wrote a reply goes back to the queue with it as the draft.
local function sync_tasks(state: any): boolean
	local changed = false
	for _, item in state.items do
		if item.triage == "doing" then
			local task = runtime.task(item.id)
			local status = if task then task.state else "closed"
			local result = if task and type(task.result) == "string" then task.result else nil
			if status ~= item.task_state or result ~= item.task_raw then
				changed = true
				item.task_state, item.task_raw, item.result = status, result, result
				if status == "done" then
					local reply = result and string.match(result, "<reply>%s*(.-)%s*</reply>")
					item.result = result and string.gsub(result, "%s*<reply>.-</reply>%s*", "\n")
					if reply and reply ~= "" then
						if not item.analysis then
							item.agent = "done"
							item.analysis = view.blank_analysis()
						end
						item.analysis.state, item.analysis.draft, item.edited = "reply", reply, nil
						item.triage = nil
						record(all_ids(item), nil)
					end
					state.flash = "omp 本轮结束，请确认结果：" .. item.name
					log(state, "omp", "本轮结束：" .. item.name)
					reselect(state, nil)
				end
			end
		end
	end
	if changed then
		-- A task's state decides which view it belongs in.
		reselect(state, nil)
	end
	return changed
end

local function schedule_tasks(state: any)
	tern.timer(TASK_POLL_MS, function()
		if not alive(state) then
			return
		end
		if sync_tasks(state) then
			render(state)
		end
		schedule_tasks(state)
	end)
end

-- Where each source's next page starts. A source you have paged through keeps its
-- place across refreshes, which only ever read the newest page; one you haven't
-- follows the newest page's cursor.
local function note_cursor(state: any, key: string, data: any, since: number, previous: any, more: boolean)
	local token = data.page_token
	local has_next = data.has_more == true and type(token) == "string" and token ~= ""
		and not (previous and previous.token == token)
	if more then
		state.cursors[key] = if has_next then { token = token, since = since, paged = true } else { exhausted = true }
	elseif not (previous and (previous.paged or previous.exhausted)) then
		state.cursors[key] = if has_next then { token = token, since = since } else nil
	end
end

-- Searches each source: the newest page, or with `more`, the next page of those that
-- have one. Lookback is part of the key, since a cursor belongs to its search.
local function search_sources(state: any, more: boolean, after: () -> ())
	local sources = {}
	local function add(filters: { string }, mention: boolean)
		local key = table.concat(filters, " ") .. "|" .. tostring(settings.get("lookback_days"))
		local cursor = state.cursors[key]
		if not more or (cursor and cursor.token) then
			table.insert(sources, { filters = filters, mention = mention, key = key })
		end
	end
	if settings.get("source_mention") or not settings.get("hide_atall") then
		add({ "--is-at-me" }, true)
	end
	if settings.get("source_dm") then
		add({ "--chat-type", "p2p" }, false)
	end
	local star_ids = {}
	for _, star in stars() do
		table.insert(star_ids, star.id)
	end
	if #star_ids > 0 and settings.get("source_star") then
		add({ "--sender", table.concat(star_ids, ",") }, false)
	end
	if #sources == 0 then
		after()
		return
	end
	local results, waiting, problem = {}, #sources, nil
	for _, source in sources do
		local previous = state.cursors[source.key]
		local since = if more then previous.since else os.time() - settings.get("lookback_days") * 86400
		feishu.search(source.filters, settings.get("lookback_days"), function(data, err)
			waiting -= 1
			if err then
				problem = err
				if more then
					-- A cursor that fails won't work later; the next refresh starts over.
					state.cursors[source.key] = nil
				end
			else
				table.insert(results, { messages = data.messages, mention = source.mention })
				note_cursor(state, source.key, data, since, previous, more)
			end
			if waiting == 0 and alive(state) then
				local function finish()
					state.problem = problem
					merge(state, results)
					after()
				end
				if not settings.get("hide_muted") then
					finish()
					return
				end
				local ids, seen = {}, {}
				local function add_chat(chat_id: string, chat_type: string)
					if chat_type ~= "p2p" and chat_id ~= "" and not seen[chat_id] then
						seen[chat_id] = true
						table.insert(ids, chat_id)
					end
				end
				for _, item in state.items do
					add_chat(item.chat_id, item.chat_type)
				end
				for _, result in results do
					for _, message in result.messages do
						add_chat(tostring(message.chat_id or ""), tostring(message.chat_type or "group"))
					end
				end
				feishu.chat_settings(ids, function(prefs, pref_err)
					if not alive(state) then
						return
					end
					state.chat_settings = prefs
					if pref_err then
						problem = if problem then problem .. "\n" .. pref_err else pref_err
					end
					finish()
				end)
			end
		end, if more then { token = previous.token, since = since } else { since = since })
	end
end

-- Whether any enabled source has an older page left to read.
local function has_more(state: any): boolean
	local suffix = "|" .. tostring(settings.get("lookback_days"))
	for key, cursor in state.cursors do
		if cursor.token and string.sub(key, -#suffix) == suffix then
			return true
		end
	end
	return false
end

-- Reads the next page of each source into the queue. Older messages wait to be
-- selected before omp reads them, so looking further back never starts a burst of work.
local function load_more(state: any)
	if state.loading or not state.me or not has_more(state) then
		return
	end
	local before = {}
	for _, item in state.items do
		before[item.id] = true
	end
	state.loading, state.loading_more, state.problem = true, true, nil
	render(state)
	search_sources(state, true, function()
		local added = 0
		for _, item in state.items do
			if not before[item.id] then
				added += if item.triage or item.hidden then 0 else 1
				item.backlog = true
			end
		end
		sync_read(state, function()
			state.loading, state.loading_more = false, false
			-- A failure already shows in the notice at the top, until the next refresh clears it.
			state.flash = if state.problem then nil
				elseif added > 0 then "又加载了 " .. tostring(added) .. " 条待处理消息，选中后才会分析"
				elseif has_more(state) then "这一页没有新的待处理消息，可以继续加载"
				else "这段时间内的消息都已加载"
			reselect(state, nil)
			sync_tasks(state)
			pump(state)
			render(state)
		end)
	end)
end

local function refresh(state: any)
	if state.loading or not alive(state) then
		return
	end
	state.loading, state.problem = true, nil
	state.last_refresh = os.time()

	feishu.whoami(function(me, err)
		if not alive(state) then
			return
		end
		if err then
			state.loading, state.problem = false, err
			render(state)
			return
		end
		state.me = me
		local function after_agenda()
			search_sources(state, false, function()
				-- Before the backlog line is drawn, so unread messages get analyzed first.
				sync_read(state, function()
					state.loading = false
					state.has_snapshot = state.problem == nil or #state.items > 0 or state.has_snapshot
					if not state.backlog_marked then
						state.backlog_marked = true
						for at, item in visible({ items = state.items, view = "pending" }) do
							item.backlog = at > settings.get("backlog")
						end
					end
					prune(state)
					sync_replies(state)
					sync_tasks(state)
					reselect(state, nil)
					local item = current(state)
					if item then
						load_thread(state, item, function() end)
					end
					pump(state)
					render(state)
				end)
			end)
		end
		if not settings.get("use_agenda") then
			after_agenda()
			return
		end
		feishu.agenda(function(agenda, agenda_err)
			if not alive(state) then
				return
			end
			state.agenda, state.agenda_error = if agenda_err then nil else agenda, agenda_err
			after_agenda()
		end)
	end)
end

-- Checks every minute, so a changed interval applies without reopening.
local function schedule_poll(state: any)
	state.poll = tern.timer(60000, function()
		if not alive(state) then
			return
		end
		local minutes = settings.get("poll_minutes")
		if minutes > 0 and os.time() - (state.last_refresh or os.time()) >= minutes * 60 then
			refresh(state)
		end
		schedule_poll(state)
	end)
end

----------------------------------------------------------------------------
-- Decisions

local function set_focus(state: any, mode: string?)
	state.mode = mode
	local id = if mode == "draft" then view.DRAFT_ID
		elseif mode == "command" then view.COMMAND_ID
		elseif mode == "setting" then view.field_control_id(state.settings_cursor)
		else tern.json.null
	state.cx:frame({ { "focus", id } })
end

local function resolve(state: any, item: any, triage: string, verb: string)
	local at = index_in(visible(state), item.id)
	state.undo = { id = item.id, kind = "triage", previous = item.triage }
	item.triage = triage
	item.reopened, item.task_new = nil, nil
	record(all_ids(item), triage)
	state.flash = verb .. "：" .. item.name
	log(state, "你", verb .. "：" .. item.name .. "（" .. item.chat .. "）")
	reselect(state, at)
end

local function open_message(state: any, item: any)
	local link = item.link
	-- Never open a protocol a message could supply.
	if type(link) == "string" and (
		string.match(link, "^https://applink%.feishu%.cn/client/chat/open%?")
		or string.match(link, "^https://applink%.larksuite%.com/client/chat/open%?")
	) then
		state.cx:open(link)
	else
		state.cx:toast("error", "该消息没有可用的原消息链接", item.id)
	end
end

-- Puts the draft on the clipboard and goes to the chat; you send it there.
local function copy_and_go(state: any, item: any)
	local text = draft_text(item)
	if string.find(text, "%S") then
		state.cx:copy(text)
	end
	open_message(state, item)
end

local function hand_off(state: any, item: any)
	copy_and_go(state, item)
	if item.triage ~= "handoff" then
		item.handoff_at = os.time()
		resolve(state, item, "handoff", "已复制，去飞书发送")
	end
end

local TAB_TITLE_CHARS = 24

local function clip(text: string, chars: number): string
	text = string.gsub(text, "%s+", " ")
	local at = utf8.offset(text, chars + 1)
	return if at then string.sub(text, 1, at - 1) .. "…" else text
end

-- The tab's name: what it works on, then whose message it came from.
local function tab_title(item: any, task: string?): string
	local a = item.analysis
	local what = if task and a and a.task and a.task.title ~= "" then a.task.title
		elseif a and a.summary ~= "" then a.summary
		else feishu.clean(item.content)
	local who = if item.chat_type == "p2p" then item.name else item.name .. "@" .. item.chat
	return "飞书｜" .. clip(what, TAB_TITLE_CHARS) .. " · " .. clip(who, 16)
end

-- Confirmed tasks get a relevance check before opening; direct `o` stays manual.
local function start_task(state: any, item: any, task: string?)
	if item.preparing_task then
		return
	end
	item.preparing_task = true
	local latest, content, triage = item.latest_id or item.id, item.content, item.triage
	state.flash = if task then "正在判断任务与飞书消息的关联性…" else "正在准备 omp…"
	local function prepare()
		agent.prepare_task(item, feishu.clean, task, extras(state, item).notice, function(prompt, cost, err)
			state.spent += cost
			item.preparing_task = nil
			if not alive(state) then
				return
			end
			if latest ~= (item.latest_id or item.id) or content ~= item.content or triage ~= item.triage
				or item.hidden or (task ~= nil and (task ~= task_text(item) or view.stale(item))) then
				state.flash = "任务或消息已变化，请重新确认后再执行"
			elseif err then
				state.flash = "执行前分析失败，请重试"
				state.cx:toast("error", state.flash, err)
			else
				item.task_state, item.task_raw, item.result = "starting", nil, nil
				runtime.set_task(item.id, { prompt = prompt, state = "starting", title = tab_title(item, task) })
				resolve(state, item, "doing", "已开 omp")
				state.cx:open(TASK_LINK .. item.id)
			end
			render(state)
		end)
	end
	if task then
		load_thread(state, item, prepare)
	else
		prepare()
	end
end

-- What `a` does is what the row says it will.
local function primary(state: any, item: any)
	local action = view.next_action(item)
	if action.key == "archive" then
		resolve(state, item, "archived", "已归档")
	elseif action.key == "copy" then
		hand_off(state, item)
	elseif action.key == "task" then
		start_task(state, item, task_text(item))
	elseif action.key == "jump" then
		item.task_new = nil
		state.cx:open(TASK_LINK .. item.id)
	elseif action.key == "reopen" then
		local task = runtime.task(item.id)
		if task then
			task.state = "starting"
			runtime.set_task(item.id, task)
			item.task_state = "starting"
			state.cx:open(TASK_LINK .. item.id)
		else
			start_task(state, item, if item.analysis then task_text(item) else nil)
		end
	end
end

local function undo(state: any)
	local last = state.undo
	if not last then
		return
	end
	state.undo = nil
	if last.kind == "rule" then
		settings.set_rule(last.chat_id, last.previous)
		apply_rules(state)
		state.flash = "已撤销会话规则"
		state.selected = last.id
		reselect(state, 1)
		pump(state)
		return
	end
	local item = by_id(state, last.id)
	if not item then
		return
	end
	record(all_ids(item), last.previous)
	state.flash = "已撤销：" .. item.name
	log(state, "你", "撤销了对 " .. item.name .. " 的操作")
	item.triage = last.previous
	-- Whatever was detected stays taken back: only what you say from now on counts.
	item.spoken = nil
	if last.previous == "handoff" then
		item.handoff_at = os.time()
	end
	state.view, state.person = "pending", nil
	state.selected = item.id
	state.draft_cursor = edit.len(field_text(item))
end

-- A turn of conversation about the selected message, in its omp session.
local function run_command(state: any)
	local said = state.command
	local item = current(state)
	if not string.find(said, "%S") or state.talking or not item then
		return
	end
	if item.no_agent then
		state.flash = "这条不交给 agent。按 g 让 omp 分析后再聊"
		return
	end
	state.command, state.command_cursor = "", 0
	state.talking = item.id
	item.talk = item.talk or {}
	table.insert(item.talk, { me = true, text = said })
	state.flash = "omp 正在回答…"
	log(state, "你", "对 omp 说：" .. said)
	cache.save(state)
	load_thread(state, item, function()
		local current_judgment = {
			decision = if item.analysis then item.analysis.state else "未判断",
			draft = draft_text(item),
			task = task_text(item),
		}
		agent.converse(item, extras(state, item), current_judgment, said, function(reply, change, session, cost, err)
			state.spent += cost
			state.talking = nil
			item.session = session or item.session
			if not alive(state) then
				return
			end
			if err then
				table.insert(item.talk, { text = "（失败）" .. err })
				state.flash = "omp 回答失败"
				log(state, "omp", "回答失败：" .. err)
			else
				table.insert(item.talk, { text = reply :: string })
				state.flash = "omp 已回答"
				if change.state or change.draft or change.task then
					if not item.analysis then
						item.agent = "done"
						item.analysis = view.blank_analysis()
					end
					local a = item.analysis
					a.state = change.state or a.state
					if change.draft then
						a.draft, item.edited = change.draft, nil
					end
					if change.task then
						a.task.prompt, item.task_edited = change.task, nil
					end
					a.risk = change.risk or a.risk
					if item.id == state.selected then
						state.draft_cursor = edit.len(field_text(item))
					end
					state.flash = "omp 已更新判断"
					reselect(state, nil)
				end
			end
			render(state)
		end)
	end)
end

local function toggle_star(state: any, item: any)
	local list, found = {}, false
	for _, star in stars() do
		if star.id == item.sender_id then
			found = true
		else
			table.insert(list, star)
		end
	end
	if not found then
		table.insert(list, { id = item.sender_id, name = item.name })
	end
	tern.kv.set("stars", tern.json.array(list))
	state.flash = (if found then "已取消星标：" else "已星标：") .. item.name
	if not found then
		refresh(state)
	end
end

local function select_item(state: any, id: string)
	if id ~= state.selected then
		-- Words and notices are about one item; they must not carry over to the next.
		state.command, state.command_cursor, state.flash = "", 0, nil
	end
	state.selected = id
	local item = current(state)
	state.draft_cursor = edit.len(if item then field_text(item) else "")
	if item then
		load_thread(state, item, function() end)
	end
	if state.mode == "draft" then
		set_focus(state, nil)
	end
	pump(state)
end

local function move(state: any, direction: number)
	local shown = visible(state)
	if #shown == 0 then
		return
	end
	local target = shown[math.clamp(index_in(shown, state.selected) + direction, 1, #shown)]
	select_item(state, target.id)
end

local function set_view(state: any, id: string?, person: string?)
	if id then
		state.view = id
	end
	state.person = person
	state.selected = nil
	state.command, state.command_cursor, state.flash = "", 0, nil
	reselect(state, 1)
	pump(state)
end

local function set_source(state: any, source: string?)
	if source ~= "all" and source ~= "mention" and source ~= "dm" then
		return
	end
	state.source, state.person = source, nil
	state.selected = nil
	reselect(state, 1)
	pump(state)
end

local function editable(item: any): boolean
	return item.analysis ~= nil and not view.locked(item) and item.triage ~= "doing"
end

-- Editing works without a draft too: you can always write the reply yourself.
local function start_edit(state: any, item: any)
	if view.locked(item) or item.agent == "running" or item.triage == "doing" or view.stale(item) then
		return
	end
	if not item.analysis then
		item.agent = "done"
		item.analysis = view.blank_analysis()
	end
	if item.analysis.state == "fyi" then
		item.analysis.state = "reply"
	end
	state.draft_cursor = edit.len(field_text(item))
	set_focus(state, "draft")
end

-- Hands one message to omp, whatever the settings say about its chat.
local function force_analysis(state: any, item: any)
	if view.locked(item) or item.agent == "running" then
		return
	end
	if item.analysis and not item.analysis.manual then
		return
	end
	item.analysis = nil
	item.force, item.no_agent, item.backlog, item.agent, item.settle_at = true, false, false, "queued", nil
	pump(state)
end

local function set_chat_rule(state: any, item: any, mode: string)
	local before = settings.rules()[item.chat_id]
	local rule = if before and before.mode == mode then nil else { mode = mode, name = item.chat }
	settings.set_rule(item.chat_id, rule)
	state.undo = { kind = "rule", chat_id = item.chat_id, previous = before, id = item.id }
	apply_rules(state)
	local at = index_in(visible(state), item.id)
	state.flash = if not rule then "已移除规则：" .. item.chat
		elseif mode == "hide" then "不再显示：" .. item.chat
		else "不再交给 agent：" .. item.chat
	log(state, "你", state.flash)
	reselect(state, at)
	pump(state)
end

-- After a setting changes: what it decides takes effect at once.
local function settings_changed(state: any)
	apply_rules(state)
	reselect(state, 1)
	pump(state)
end

local function move_settings_cursor(state: any, direction: number)
	local ids = {}
	for _, group in settings.GROUPS do
		for _, field in settings.FIELDS do
			if field.group == group.id then
				table.insert(ids, field.id)
			end
		end
	end
	local at = table.find(ids, state.settings_cursor) or 1
	state.settings_cursor = ids[math.clamp(at + direction, 1, #ids)]
end

local function key_in_settings(state: any, key: any): boolean?
	local k = key.text or key.name
	local field = settings.field(state.settings_cursor)
	if key.name == "escape" or k == "," then
		state.page = nil
		refresh(state)
	elseif key.name == "down" or k == "j" then
		move_settings_cursor(state, 1)
	elseif key.name == "up" or k == "k" then
		move_settings_cursor(state, -1)
	elseif field.kind == "text" and (key.name == "enter" or key.name == "space") then
		state.field_cursor = edit.len(settings.get(field.id))
		set_focus(state, "setting")
	elseif key.name == "enter" or key.name == "space" or key.name == "right" or k == "l" then
		settings.cycle(field.id)
		settings_changed(state)
	elseif key.name == "left" or k == "h" then
		settings.cycle(field.id, -1)
		settings_changed(state)
	else
		return false
	end
	return true
end

----------------------------------------------------------------------------
-- The block

local function facts_of(state: any): any
	local facts: any = { running = 0, deep = 0, reply = 0, doing = 0, fyi = 0, pending = 0 }
	local counts = {}
	for _, def in VIEWS do
		local n = 0
		for _, item in state.items do
			if shows({ view = def.id }, item) then
				n += 1
			end
		end
		counts[def.id] = n
	end
	for _, item in state.items do
		local status = view.status(item)
		facts.running += if status == "running" then 1 else 0
		if not item.hidden then
			facts.deep += if status == "deep" then 1 else 0
			facts.reply += if status == "reply" then 1 else 0
			facts.doing += if item.triage == "handoff" or item.triage == "doing" then 1 else 0
			facts.fyi += if status == "fyi" and not item.triage then 1 else 0
		end
		facts.pending += if pending(item) then 1 else 0
	end
	facts.views = {}
	for _, def in VIEWS do
		table.insert(facts.views, { id = def.id, label = def.label, count = counts[def.id] })
	end
	facts.people = {}
	for _, star in stars() do
		local n = 0
		for _, item in state.items do
			n += if item.sender_id == star.id and needs_me(item) then 1 else 0
		end
		table.insert(facts.people, { id = star.id, name = star.name, count = n })
	end
	facts.queue = visible(state)
	facts.has_more = has_more(state)
	facts.item = current(state)
	facts.dialog_item = state.dialog and by_id(state, state.dialog.id)
	facts.draft = if facts.item then field_text(facts.item) else ""
	facts.reply_draft = if facts.item then draft_text(facts.item) else ""
	return facts
end

local function act(state: any, name: string, value: string?, cx: any)
	local item = current(state)
	if name == "view" then
		set_view(state, value, nil)
	elseif name == "source" then
		set_source(state, value)
	elseif name == "load-more" then
		load_more(state)
	elseif name == "settings" then
		if state.mode then set_focus(state, nil) end
		state.page = if state.page == "settings" then nil else "settings"
	elseif name == "person" then
		set_view(state, nil, if state.person == value then nil else value)
	elseif name == "refresh" then
		refresh(state)
	elseif name == "undo" then
		undo(state)
	elseif name == "run-command" then
		run_command(state)
	elseif name == "set" then
		local id, at = string.match(value or "", "^([%w_]+):(%d+)$")
		local field = id and settings.field(id)
		if field and field.choices and field.choices[tonumber(at) :: number] ~= nil then
			settings.set(id :: string, field.choices[tonumber(at) :: number])
			state.settings_cursor = id
			settings_changed(state)
		end
	elseif name == "rule-del" and value then
		settings.set_rule(value, nil)
		settings_changed(state)
	elseif name == "rule-mode" and value then
		local rule = settings.rules()[value]
		if rule then
			settings.set_rule(value, { mode = if rule.mode == "hide" then "manual" else "hide", name = rule.name })
			settings_changed(state)
		end
	elseif not item then
		return
	elseif name == "open-thread" then
		if state.mode then set_focus(state, nil) end
		state.dialog = { id = item.id }
	elseif name == "primary" then
		if view.needs_confirm(item) then
			state.flash = "这条涉及" .. item.analysis.risk .. "，请点击按钮确认后再执行"
		else
			primary(state, item)
		end
	elseif name == "confirm-task" then
		if view.needs_confirm(item) then
			primary(state, item)
		end
	elseif name == "copy" then
		if view.stale(item) then
			state.flash = "有新消息，等新的判断出来再复制"
		else
			copy_and_go(state, item)
		end
	elseif name == "confirm-reply" and item.triage == "handoff" and item.spoken then
		resolve(state, item, "replied", "已确认回复")
	elseif name == "archive" then
		if not view.locked(item) then
			resolve(state, item, "archived", "已归档")
		end
	elseif name == "omp" then
		if item.triage == "doing" then
			item.task_new = nil
			state.cx:open(TASK_LINK .. item.id)
		else
			start_task(state, item, nil)
			log(state, "你", "用 omp 打开：" .. item.name)
		end
	elseif name == "force" then
		force_analysis(state, item)
	elseif name == "snooze" then
		local status = view.status(item)
		if status == "snoozed" then
			state.undo = nil
			record(all_ids(item), nil)
			item.triage = nil
			state.flash = "已移回需要我：" .. item.name
			reselect(state, nil)
		elseif not view.locked(item) then
			resolve(state, item, "snoozed", "稍后处理")
		end
	elseif name == "redraft" then
		if view.status(item) == "failed" then
			item.agent, item.settle_at = "queued", nil
			pump(state)
		end
	elseif name == "retry" then
		item.agent, item.settle_at = "queued", nil
		pump(state)
	elseif name == "edit" then
		start_edit(state, item)
	elseif name == "open" then
		open_message(state, item)
	end
end

local function key_in_field(state: any, key: any): boolean?
	if key.name == "escape" then
		local was = state.mode
		set_focus(state, nil)
		if was == "setting" then
			settings_changed(state)
		end
		return true
	end
	if state.mode == "setting" then
		local id = state.settings_cursor
		if key.name == "enter" then
			set_focus(state, nil)
			settings_changed(state)
			return true
		end
		local field = { text = settings.get(id), cursor = state.field_cursor }
		local changed = edit.key(field, key)
		settings.set(id, field.text)
		state.field_cursor = field.cursor
		return changed
	end
	if state.mode == "command" then
		-- The box goes away with the states that can't use it, such as a running task.
		local target = current(state)
		if target and not view.can_adjust(target) then
			set_focus(state, nil)
			return true
		end
		if key.name == "enter" then
			set_focus(state, nil)
			run_command(state)
			return true
		end
		local field = { text = state.command, cursor = state.command_cursor }
		local changed = edit.key(field, key)
		state.command, state.command_cursor = field.text, field.cursor
		return changed
	end
	local item = current(state)
	if not item or not editable(item) then
		set_focus(state, nil)
		return true
	end
	local field = { text = field_text(item), cursor = state.draft_cursor }
	local changed
	if key.name == "enter" then
		changed = edit.key(field, { name = "paste", text = "\n" })
	else
		changed = edit.key(field, key)
	end
	if field.text ~= field_text(item) then
		if item.analysis.state == "deep" then
			item.task_edited = field.text
		else
			item.edited = field.text
		end
	end
	state.draft_cursor = field.cursor
	return changed
end

-- The view left open, unless this version no longer has it.
local function view_from(saved: any): string
	for _, def in VIEWS do
		if type(saved) == "table" and saved.view == def.id then
			return def.id
		end
	end
	return "pending"
end

tern.block.define("inbox", {
	font = "sans",
	init = function(cx, _args, saved)
		local previous = running[cx.pane]
		if previous and previous.poll then
			previous.poll:cancel()
		end
		local state: any = {
			cx = cx,
			items = {},
			log = {},
			view = view_from(saved),
			person = nil,
			selected = nil,
			active = 0,
			spent = 0,
			source = "all",
			loading = false,
			mode = nil,
			command = "",
			command_cursor = 0,
			draft_cursor = 0,
			images = {},
			settings_cursor = settings.FIELDS[1].id,
			field_cursor = 0,
			cursors = {},
		}
		running[cx.pane] = state
		if cache.restore(state) then
			state.view = view_from(if type(saved) == "table" then saved else state)
			if state.view == "mention" or state.view == "dm" then
				state.source, state.view = state.view, "pending"
			end
			state.last_refresh = state.last_refresh or os.time()
			apply_rules(state)
			sync_tasks(state)
			reselect(state, nil)
			-- Recreate only local blob handles; no download or thread fetch on reload.
			local item = current(state)
			for _, message in (if settings.get("show_images") and item and item.thread then item.thread else {}) do
				for _, key in feishu.images_in(message.content, 4) do
					local path = state.image_paths[key]
					if path then
						local ok, bytes = pcall(tern.fs.read, tern.plugin.data .. "/" .. path, MAX_IMAGE_BYTES)
						if ok then
							state.images[key] = { path = path, settled = true, blob = cx:blob(bytes, mime_of(bytes)) }
						end
					end
				end
			end
			cache.save(state)
		else
			refresh(state)
		end
		schedule_poll(state)
		schedule_tasks(state)
		return state
	end,

	title = function(state)
		local n = 0
		for _, item in state.items do
			n += if needs_me(item) then 1 else 0
		end
		return if n > 0 then "飞书 · " .. tostring(n) .. " 需要我" else "飞书工作台"
	end,

	view = function(state, cx)
		return view.render(state, facts_of(state), cx)
	end,

	event = function(state, ev, cx)
		if state.dialog then
			if ev.ev == "action" and ev.act == "close-thread" then
				state.dialog = nil
			end
			return
		end
		if ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, ev.value, cx)
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local id = string.sub(ev.item, #view.QUEUE_PREFIX + 1)
			if by_id(state, id) then
				select_item(state, id)
				if ev.ev == "activate" then
					open_message(state, current(state))
				end
			end
		elseif ev.ev == "change" and type(ev.id) == "string" then
			local id = string.match(ev.id, "%.f_([%w_]+)%.c$")
			if id and settings.field(id) then
				settings.set(id, ev.value == true)
				state.settings_cursor = id
				settings_changed(state)
			end
		elseif ev.ev == "focus" then
			local setting_id = type(ev.id) == "string" and string.match(ev.id, "%.f_([%w_]+)%.wrap%.c$")
			if setting_id then
				state.settings_cursor = setting_id
				state.field_cursor = edit.len(settings.get(setting_id))
				set_focus(state, "setting")
			elseif ev.id == view.COMMAND_ID then
				set_focus(state, "command")
			elseif ev.id == view.DRAFT_ID and current(state) then
				start_edit(state, current(state))
			end
		end
		cache.save(state)
	end,

	key = function(state, key, cx)
		-- A modal reading layer: the selection and any edit underneath stay as they are.
		if state.dialog then
			if key.name == "escape" then
				state.dialog = nil
			end
			return true
		end
		if state.mode then
			local handled = key_in_field(state, key)
			cache.save(state)
			return handled
		end
		if key.ctrl or key.meta or key.alt then
			return false
		end
		if state.page == "settings" then
			local handled = key_in_settings(state, key)
			cache.save(state)
			return handled
		end
		local k = key.text or key.name
		if key.name == "down" or k == "j" then
			move(state, 1)
		elseif key.name == "up" or k == "k" then
			move(state, -1)
		elseif k == "a" then
			act(state, "primary", nil, cx)
		elseif k == "e" then
			act(state, "edit", nil, cx)
		elseif k == "r" then
			act(state, "redraft", nil, cx)
		elseif k == "c" then
			act(state, "copy", nil, cx)
		elseif k == "s" then
			act(state, "snooze", nil, cx)
		elseif k == "x" then
			act(state, "archive", nil, cx)
		elseif k == "u" then
			undo(state)
		elseif k == "R" or key.name == "f5" then
			refresh(state)
		elseif k == "m" then
			load_more(state)
		elseif k == "/" then
			local item = current(state)
			if item and view.can_adjust(item) then
				set_focus(state, "command")
			end
		elseif k == "*" then
			local item = current(state)
			if item then
				toggle_star(state, item)
			end
		elseif key.name == "enter" then
			act(state, "open", nil, cx)
		elseif k == "," then
			state.page = "settings"
			if state.mode then
				set_focus(state, nil)
			end
		elseif k == "o" then
			act(state, "omp", nil, cx)
		elseif k == "g" then
			act(state, "force", nil, cx)
		elseif k == "i" or k == "n" then
			local item = current(state)
			if item then
				set_chat_rule(state, item, if k == "i" then "hide" else "manual")
			end
		elseif k == "6" or k == "7" then
			local source = if k == "6" then "mention" else "dm"
			set_source(state, if state.source == source then "all" else source)
		elseif string.match(k, "^[1-5]$") then
			set_view(state, VIEWS[tonumber(k) :: number].id, nil)
		else
			return false
		end
		cache.save(state)
		return true
	end,

	-- Also checkpoint at the host's lifecycle save boundary.
	save = function(state)
		cache.save(state)
		return { view = state.view }
	end,
})

--!strict
-- Which matters each view holds, in which order, and how many. The view tabs,
-- the queue, the counts and the workbench tab name all come from here.
local types = require("./types")
local status = require("./status")

type Matter = types.Matter

local views = {}

export type View = { id: string, label: string, holds: (Matter) -> boolean }

-- In tab order; `1`–`5` select the first five.
views.LIST = {
	{ id = "pending", label = "待处理", holds = status.needs_me },
	{
		id = "doing", label = "处理中",
		holds = function(m: Matter): boolean
			return m.disposition == "handoff" or (m.disposition == "doing" and not status.task_needs_me(m))
		end,
	},
	{ id = "later", label = "稍后", holds = function(m: Matter): boolean return m.disposition == "snoozed" end },
	{ id = "done", label = "已处理", holds = status.settled },
	{
		id = "fyi", label = "可忽略",
		holds = function(m: Matter): boolean return m.disposition == nil and status.of(m) == "fyi" end,
	},
	{ id = "bot", label = "@机器人", holds = function(m: Matter): boolean return m.bot_profile ~= nil and m.bot_profile ~= "" end },
} :: { View }

local BY_ID: { [string]: View } = {}
for _, v in views.LIST do
	BY_ID[v.id] = v
end

function views.known(id: any): boolean
	return type(id) == "string" and BY_ID[id] ~= nil
end

export type Selection = { view: string, source: string, person: string?, bot_profile: string? }

function views.bot_label(name: string?): string
	return if name and string.find(name, "%S") then "@" .. name else "@机器人"
end

-- The bot source is a profile-scoped record of commands, including hidden and
-- settled matters; normal views retain their source, person and rule filters.
function views.shows(sel: Selection, m: Matter): boolean
	if sel.view == "bot" then
		return sel.bot_profile ~= nil and sel.bot_profile ~= "" and m.bot_profile == sel.bot_profile
	end
	if m.hidden then
		return false
	end
	if sel.source == "mention" and not m.mention then
		return false
	elseif sel.source == "dm" and m.chat_type ~= "p2p" then
		return false
	end
	if sel.person then
		return m.sender_id == sel.person and status.needs_me(m)
	end
	local v = BY_ID[sel.view] or BY_ID.pending
	return v.holds(m)
end

-- Queue order: tasks waiting on you, then what to work on, what to answer, the rest;
-- within each, by priority, unread first, newest first.
local function group(m: Matter): number
	local s = status.of(m)
	return if status.task_needs_me(m) then 0 elseif s == "deep" then 1 elseif s == "reply" then 2 else 3
end

local function rank(m: Matter): number
	local j = m.analysis.judgment
	return if j then tonumber(string.sub(j.pri, 2)) or 2 else 1.5
end

function views.before(a: Matter, b: Matter): boolean
	local ga, gb = group(a), group(b)
	if ga ~= gb then
		return ga < gb
	end
	local ra, rb = rank(a), rank(b)
	if ra ~= rb then
		return ra < rb
	end
	local ua, ub = status.unread(a), status.unread(b)
	if ua ~= ub then
		return ua
	end
	if a.time ~= b.time then
		return a.time > b.time
	end
	return a.id < b.id
end

function views.visible(items: { Matter }, sel: Selection): { Matter }
	local shown = {}
	for _, m in items do
		if views.shows(sel, m) then
			table.insert(shown, m)
		end
	end
	table.sort(shown, views.before)
	return shown
end

-- How many matters each view holds, ignoring the source and person filters.
function views.counts(items: { Matter }, bot_profile: string?): { [string]: number }
	local counts: { [string]: number } = {}
	for _, v in views.LIST do
		counts[v.id] = 0
	end
	for _, m in items do
		if bot_profile and bot_profile ~= "" and m.bot_profile == bot_profile then counts.bot += 1 end
		if not m.hidden then
			for _, v in views.LIST do
				if v.id ~= "bot" and v.holds(m) then
					counts[v.id] += 1
				end
			end
		end
	end
	return counts
end

-- The workbench tab's name: the fixed prefix `飞书｜`, then the views you act
-- from with their counts, empty ones left out to fit Tern's 220px tab name.
local TAB_VIEWS = { "pending", "doing", "later" }

function views.tab_name(items: { Matter }, loading: boolean, problem: string?): string
	if #items == 0 and problem then
		return "飞书｜加载失败"
	elseif #items == 0 and loading then
		return "飞书｜加载中…"
	end
	local counts = views.counts(items)
	local segments = {}
	for _, id in TAB_VIEWS do
		if counts[id] > 0 then
			table.insert(segments, BY_ID[id].label .. tostring(counts[id]))
		end
	end
	return "飞书｜" .. (if #segments > 0 then table.concat(segments, "·") else "已清空")
end

return views

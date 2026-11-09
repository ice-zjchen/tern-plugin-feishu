-- External refresh work only. Search cursors are copied before requests start;
-- callbacks return one result event, never mutate the live workbench model.
local lark = require("../services/lark")

local fetch = {}

local function append_error(before: string?, err: string?): string?
	return if not err then before elseif before then before .. "\n" .. err else err
end

function fetch.run(request: any, done: (any) -> ())
	local settings, more = request.settings, request.more
	local result: any = { type = "fetched", gen = request.gen, sources = {}, cursors = {}, me = request.me }
	for key, cursor in request.cursors do result.cursors[key] = table.clone(cursor) end
	local function search()
		local sources = {}
		local function add(filters: { string }, mention: boolean)
			local key = table.concat(filters, " ") .. "|" .. tostring(settings.lookback_days)
			local cursor = result.cursors[key]
			if not more or (cursor and cursor.token) then
				table.insert(sources, { filters = filters, mention = mention, key = key })
			end
		end
		if settings.source_mention or not settings.hide_atall then add({ "--is-at-me" }, true) end
		if settings.source_dm then add({ "--chat-type", "p2p" }, false) end
		local stars = {}; for _, star in request.stars do table.insert(stars, star.id) end
		if #stars > 0 and settings.source_star then add({ "--sender", table.concat(stars, ",") }, false) end
		local waiting = #sources
		-- Mute preferences are looked up after the merge, only for chats still in question.
		if waiting == 0 then done(result); return end
		for _, source in sources do
			local previous = result.cursors[source.key]
			local since = if more then previous.since else os.time() - settings.lookback_days * 86400
			lark.search({ filters = source.filters, since = since, token = if more then previous.token else nil }, function(data, err)
				if err then
					result.error = append_error(result.error, err)
					if more then result.cursors[source.key] = nil end
				else
					table.insert(result.sources, { messages = data.messages, mention = source.mention })
					local next_page = data.has_more and data.page_token ~= (previous and previous.token)
					if more then
						result.cursors[source.key] = if next_page then { token = data.page_token, since = since, paged = true } else { exhausted = true }
					elseif not (previous and (previous.paged or previous.exhausted)) then
						result.cursors[source.key] = if next_page then { token = data.page_token, since = since } else nil
					end
				end
				waiting -= 1
				if waiting == 0 then done(result) end
			end)
		end
	end
	if more then search(); return end
	lark.whoami(function(me, err)
		if err then done({ type = "fetched", gen = request.gen, error = err }); return end
		result.me = me
		if not settings.use_agenda then search(); return end
		lark.agenda(function(agenda, _err)
			result.agenda = agenda
			search()
		end)
	end)
end

return fetch

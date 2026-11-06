--!strict
-- Read-only @me search, kept outside the matter queue. Browsing history never
-- queues AI, changes dispositions, records outcomes or downloads attachments.
local text = require("../shared/text")

local history = {}

export type State = {
	pages: { any }, tokens: { [string]: boolean }, index: number, selected: number,
	loading: boolean, gen: number, error: string?, refreshing: boolean,
}

function history.empty(): State
	return { pages = {}, tokens = {}, index = 0, selected = 0, loading = false, gen = 0, refreshing = true }
end

function history.page(h: State): any
	return h.pages[h.index]
end

function history.selected(h: State): any
	local page = history.page(h)
	return if page then page.messages[h.selected] else nil
end

local function request(h: State, refresh: boolean, out: { any })
	if h.loading then return end
	local page = history.page(h)
	if not refresh and (not page or not page.has_more) then return end
	h.loading, h.error, h.refreshing, h.gen = true, nil, refresh, h.gen + 1
	table.insert(out, { type = "history-search", gen = h.gen, token = if refresh then nil else page.page_token })
end

function history.apply(h: State, event: any): { any }
	local out = {}
	local name = event.name
	if name == "open" then
		if h.index == 0 then request(h, true, out) end
	elseif name == "refresh" then request(h, true, out)
	elseif name == "retry" then request(h, h.refreshing, out)
	elseif name == "next" or name == "previous" then
		if h.loading then return out end
		local target = h.index + (if name == "next" then 1 else -1)
		if target >= 1 and target <= #h.pages then h.index, h.selected, h.error = target, 1, nil
		elseif name == "next" then request(h, false, out) end
	elseif name == "move" then
		local page = history.page(h)
		if page and #page.messages > 0 then h.selected = math.clamp(h.selected + event.direction, 1, #page.messages) end
	elseif name == "select" then
		local page = history.page(h)
		if page and type(event.index) == "number" and page.messages[event.index] then
			h.selected = event.index
			if event.open then return history.apply(h, { name = "open-message" }) end
		end
	elseif name == "open-message" then
		local message = history.selected(h)
		if message then
			if text.is_chat_link(message.message_app_link) then table.insert(out, { type = "open", url = message.message_app_link })
			else table.insert(out, { type = "toast", title = "该消息没有可用的原消息链接", detail = message.message_id }) end
		end
	elseif name == "copy-message" then
		local message = history.selected(h)
		if message and not message.deleted then table.insert(out, { type = "copy", text = tostring(message.content or "") }) end
	elseif name == "result" then
		if event.gen ~= h.gen or not h.loading then return out end
		h.loading = false
		local page = event.page
		if not page then h.error = event.error or "消息检索失败"; return out end
		if page.has_more and (type(page.page_token) ~= "string" or page.page_token == "") then
			h.error = "服务端未返回有效分页游标"; return out
		elseif not h.refreshing and page.has_more and h.tokens[page.page_token] then
			h.error = "服务端重复返回分页游标，请刷新后重试"; return out
		end
		if h.refreshing then h.pages, h.tokens, h.index = {}, {}, 0 end
		table.insert(h.pages, page)
		h.index, h.selected = #h.pages, if #page.messages > 0 then 1 else 0
		if page.has_more then h.tokens[page.page_token] = true end
	end
	return out
end

return history

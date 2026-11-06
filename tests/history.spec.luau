--!strict
local t = require("./t")
local history = require("../src/core/history")
local update = require("../src/core/update")
local snapshot = require("../src/core/snapshot")
local schema = require("../src/shared/schema")
local matter = require("../src/core/matter")

local function page(id: string, token: string?): any
	return { messages = { { message_id = id, content = id } }, has_more = token ~= nil, page_token = token }
end

t.test("history navigates cached pages without another search", function()
	local h = history.empty()
	history.apply(h, { name = "open" })
	history.apply(h, { name = "result", gen = h.gen, page = page("first", "cursor-1") })
	local next_page = history.apply(h, { name = "next" })
	t.eq(next_page[1].token, "cursor-1")
	history.apply(h, { name = "result", gen = h.gen, page = page("second", nil) })
	t.eq(history.selected(h).message_id, "second")
	t.eq(#history.apply(h, { name = "previous" }), 0)
	t.eq(history.selected(h).message_id, "first")
	t.eq(#history.apply(h, { name = "next" }), 0)
	t.eq(history.selected(h).message_id, "second")
end)

t.test("refresh failure retains current page and retries the same operation", function()
	local h = history.empty()
	history.apply(h, { name = "open" })
	history.apply(h, { name = "result", gen = h.gen, page = page("saved", "cursor") })
	history.apply(h, { name = "refresh" })
	history.apply(h, { name = "result", gen = h.gen, error = "network failed" })
	t.eq(history.selected(h).message_id, "saved")
	t.eq(h.error, "network failed")
	local retry = history.apply(h, { name = "retry" })
	t.eq(retry[1].token, nil)
end)

t.test("late history result cannot replace a newer page", function()
	local h = history.empty()
	history.apply(h, { name = "open" })
	local gen = h.gen
	history.apply(h, { name = "result", gen = gen, page = page("first", "cursor") })
	history.apply(h, { name = "next" })
	history.apply(h, { name = "result", gen = gen, page = page("old", nil) })
	t.eq(h.loading, true); t.eq(h.index, 1)
	history.apply(h, { name = "result", gen = h.gen, page = page("second", nil) })
	t.eq(history.selected(h).message_id, "second")
end)

t.test("repeated pagination token reports failure without declaring the history complete", function()
	local h = history.empty()
	history.apply(h, { name = "open" })
	history.apply(h, { name = "result", gen = h.gen, page = page("first", "same") })
	history.apply(h, { name = "next" })
	history.apply(h, { name = "result", gen = h.gen, page = page("second", "same") })
	t.eq(h.index, 1); t.eq(#h.pages, 1)
	t.eq(history.page(h).has_more, true)
	t.eq(h.error ~= nil, true)
end)

t.test("history browsing never queues analysis or inserts results into matters", function()
	local settings = {}
	for _, field in schema.FIELDS do settings[field.id] = field.default end
	local model = snapshot.empty({ settings = settings, stars = {}, rules = {}, now = 1794000000 })
	model.loaded, model.queue_enabled = true, true
	local m = matter.make({ message_id = "matter", chat_type = "p2p" }, model.cfg.now)
	table.insert(model.items, m)
	local out = update.apply(model, { type = "action", name = "history" })
	t.eq(model.page, "history")
	t.eq(m.analysis.phase, "queued")
	for _, effect in out do t.eq(effect.type == "analyze" or effect.type == "thread", false) end
	local h = model.history :: history.State
	update.apply(model, { type = "history", name = "result", gen = h.gen, page = page("past-message", "cursor") })
	t.eq(#model.items, 1); t.eq(model.items[1].id, "matter")
	t.eq(snapshot.encode(model).history, nil)
end)

t.done()

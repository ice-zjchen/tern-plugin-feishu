--!strict
-- One shared snapshot writer, not one timer per pane. A load replaces the
-- writer's owner; callbacks and saves from the retired model cannot overwrite it.
local tern = require("tern")
local snapshot = require("../core/snapshot")
local types = require("../core/types")

type Model = types.Model
type Config = types.Config

local store = {}
local SAVE_DELAY_MS = 500
local DECISION_TTL = 30 * 86400
local KEY = "inbox_snapshot"
local active: Model? = nil
local retired: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local pending: Model? = nil
local timer: any = nil
local generation = 0

-- This is only a resurrection/tombstone ledger for raw message ids outside the
-- cached queue. Live dispositions belong solely to the model, not this table.
function store.decisions(): { [string]: any }
	local stored = tern.kv.get("decisions")
	return if type(stored) == "table" then stored else {}
end

function store.record(ids: { string }, outcome: string?)
	local stored = store.decisions()
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

function store.stars(): { any }
	local stored = tern.kv.get("stars")
	return if type(stored) == "table" then stored else {}
end

function store.set_stars(list: { any })
	tern.kv.set("stars", tern.json.array(list))
end

local function cancel()
	generation += 1
	pending = nil
	local previous = timer
	timer = nil
	if previous then
		previous:cancel()
	end
end

local function owns(model: Model): boolean
	if retired[model] then
		return false
	end
	if active == nil then
		active = model
	end
	return active == model
end

local function write(model: Model)
	if model.loaded then
		tern.kv.set(KEY, snapshot.encode(model))
	end
end

-- Flush before starting any AI turn. Saving the running marker is what keeps a
-- reload from replaying a turn that may already have used tools.
function store.save_now(model: Model)
	if not owns(model) then
		return
	end
	cancel()
	write(model)
end

function store.save(model: Model)
	if not owns(model) or pending == model then
		return
	end
	pending = model
	generation += 1
	local ticket = generation
	timer = tern.timer(SAVE_DELAY_MS, function()
		if ticket ~= generation or active ~= model or pending ~= model then
			return
		end
		timer, pending = nil, nil
		write(model)
	end)
end

function store.flush(model: Model?)
	local current = model or active
	if current then
		store.save_now(current)
	end
end

function store.load(cfg: Config): Model?
	-- A debounced edit belongs to the old model until it has reached storage.
	-- Flush it first, then retire the model even if validation of storage fails.
	local previous = active
	if previous then
		store.save_now(previous)
		retired[previous] = true
	end
	cancel()
	active = nil
	local model = snapshot.decode(tern.kv.get(KEY), cfg)
	active = model
	return model
end

function store.close(model: Model)
	if active ~= model then
		-- Closing an old pane must not flush/cancel the current pane's writer.
		retired[model] = true
		return
	end
	store.save_now(model)
	retired[model] = true
	active = nil
end

return store

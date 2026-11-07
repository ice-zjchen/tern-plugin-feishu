-- The host owns task-request:<id>; the window owns task-state:<id> and
-- task-pane:<pane>. Never merge a callback into another half's record. A result
-- is visible only when it belongs to the current request number.
local tern = require("tern")
local task_rules = require("../core/task")
local bridge = {}
bridge.LINK = "tern-plugin-feishu://task/"
bridge.CLEANUP_LINK = "tern-plugin-feishu://task-cleanup/"

function bridge.cleanup_id(url: string): string?
	return string.match(url, "^tern%-plugin%-feishu://task%-cleanup/([%w_%-]+)$")
end

local function get(key)
	local value = tern.kv.get(key)
	return if type(value) == "table" then value else nil
end

function bridge.id_of(url: string): string?
	return string.match(url, "^tern%-plugin%-feishu://task/([%w_%-]+)$")
end

function bridge.request(id: string): any
	return get("task-request:" .. id)
end

function bridge.state(id: string): any
	return get("task-state:" .. id)
end

-- A joined read view, never written back as a unit.
function bridge.task(id: string): any
	return task_rules.join(bridge.request(id), bridge.state(id))
end

-- Host only. The counter persists even when a settled task's request is pruned,
-- so a late callback from its previous pane can never match a new attempt.
function bridge.start(id: string, confirmed: any, before_publish: (any) -> ()): any
	local counter = tern.kv.get("task-sequence") or 0
	assert(type(counter) == "number" and counter >= 0 and counter < 9007199254740991 and counter % 1 == 0, "任务请求计数损坏")
	counter += 1
	local request = {
		version = 2, matter_id = id, revision = confirmed.revision, request_id = counter,
		prompt = confirmed.prompt, title = confirmed.title, task_text = confirmed.task_text,
		workspace = confirmed.workspace, default_workspace = confirmed.default_workspace,
	}
	assert(task_rules.valid_request(request), "任务确认请求格式无效")
	tern.kv.set("task-sequence", counter)
	-- A confirmation must be durable before the window can observe this request.
	before_publish(request)
	tern.kv.set("task-request:" .. id, request)
	return request
end

-- Host only. Window-owned records are cleared when their pane closes or emits
-- another lifecycle event; removing the request makes them immediately invisible.
function bridge.remove(id: string)
	tern.kv.set("task-request:" .. id, nil)
end

-- Window only. Reject callbacks from previous task attempts.
function bridge.update(id: string, request_id: number, patch: any): boolean
	local request = bridge.request(id)
	if not request or request.request_id ~= request_id then return false end
	local previous = bridge.state(id)
	local state = if previous and previous.request_id == request_id then table.clone(previous) else { request_id = request_id }
	for key, value in patch do state[key] = value end
	tern.kv.set("task-state:" .. id, state)
	return true
end

function bridge.binding(pane: number): any
	return get("task-pane:" .. tostring(pane))
end

function bridge.bind(pane: number, id: string, request_id: number)
	tern.kv.set("task-pane:" .. tostring(pane), { id = id, request_id = request_id })
end

function bridge.unbind(pane: number)
	tern.kv.set("task-pane:" .. tostring(pane), nil)
end

function bridge.clear_orphan(id: string)
	if not bridge.request(id) then tern.kv.set("task-state:" .. id, nil) end
end

-- One-time bootstrap from the old combined records. Request 0 is reserved for
-- migrated attempts. Steady-state writes above are always single-owner.
local function migrate_task(id)
	local old = get("task:" .. id)
	if not old then return end
	if not bridge.request(id) then
		local body = string.match(old.prompt or "", "\n## 任务\n(.-)\n\n## 飞书消息")
		tern.kv.set("task-request:" .. id, { request_id = 0, prompt = old.prompt, title = old.title, task_text = body })
		tern.kv.set("task-state:" .. id, { request_id = 0, state = old.state or "closed", pane = old.pane,
			began = old.began, result = old.result, launched = old.pane ~= nil })
		if type(old.pane) == "number" then bridge.bind(old.pane, id, 0) end
	end
	tern.kv.set("task:" .. id, nil)
end

function bridge.migrate(ids: { string }?)
	for _, id in ids or {} do migrate_task(id) end
	local old = get("task_panes")
	if old then
		for pane, id in old do
			migrate_task(id)
			local request = bridge.request(id)
			if request and tonumber(pane) then bridge.bind(tonumber(pane), id, request.request_id) end
		end
		tern.kv.set("task_panes", nil)
	end
end

return bridge

-- Window half: palette commands, explicit task launch, and task-tab events.
-- All shared record shapes and ownership live in shared/bridge; launch rules
-- live in core/task. No workbench state or queue decisions are written here.
local tern = require("tern")
local bridge = require("../shared/bridge")
local launch = require("../services/launch")
local task_rules = require("../core/task")

bridge.migrate()

local function open_workbench(cx, args)
	if not cx:new_block("tern-plugin-feishu.inbox", args, "tab") then
		cx:toast("error", "飞书插件未就绪", "请确认当前主机已安装 tern-plugin-feishu 插件。")
	end
end

tern.command({ id = "inbox", title = "飞书 Feishu / Lark：打开工作台", keys = { "ctrl+alt+shift+f" },
	run = function(cx) open_workbench(cx, {}) end })
tern.command({ id = "bot", title = "飞书 Feishu / Lark：查看机器人指令与任务聚合",
	run = function(cx) open_workbench(cx, { "bot" }) end })

local function path_command(id, title, key, placeholder)
	tern.command({ id = id, title = title, run = function(cx)
		cx:prompt({ placeholder = placeholder, value = tern.kv.get(key) or "" }):next(function(value, err, next_cx)
			if err then
				if next_cx then next_cx:toast("error", "无法保存", err) end
			elseif value ~= nil then
				tern.kv.set(key, if value == "" then nil else value)
				if next_cx then next_cx:toast("success", "已保存", "下一次分析或任务启动生效。") end
			end
		end)
	end })
end
path_command("agent", "飞书 Feishu / Lark：设置 AI 程序路径", "agent", "AI 程序可执行文件路径（留空自动查找）")
path_command("cli", "飞书 Feishu / Lark：设置 lark-cli 路径", "cli", "lark-cli 可执行文件路径（留空使用 PATH）")

local function agent_at(cx, pane)
	for _, agent in cx.agents:list() do if agent.pane == pane then return agent end end
	return nil
end

local function open_task(link, cx)
	local cleanup = bridge.cleanup_id(link.url)
	if cleanup then
		bridge.clear_orphan(cleanup)
		return { handled = true }
	end
	local id = bridge.id_of(link.url)
	if not id then return nil end
	local current = bridge.task(id)
	if not current then
		cx:toast("error", "无法打开任务", "这条消息的任务已不存在")
		return { handled = true }
	end
	local request_id = current.request_id
	local ok, err = pcall(function()
		local open = if type(current.pane) == "number" then agent_at(cx, current.pane) else nil
		local route = task_rules.route(current, open ~= nil and open.state ~= "exited")
		if route ~= "focus" then
			assert(task_rules.valid_request(current) and current.matter_id == id, "旧任务需回工作台重新确认执行目录")
		end
		if route == "focus" then cx.layout:focus(current.pane); return end
		if route ~= "start" then
			if current.state ~= "done" then bridge.update(id, request_id, { state = "closed" }) end
			return
		end
		-- Claim before spawning. A duplicate link or reload cannot replay the same
		-- launch; an interrupted claim returns closed for an explicit retry.
		assert(bridge.update(id, request_id, { state = "starting", launched = true, began = false, result = false }), "任务请求已变化")
		local env = launch.prepare()
		if env.warning then cx:toast("info", "工作目录已回退", env.warning) end
		local cwd = launch.task_workspace(current.workspace, current.default_workspace)
		-- A different workspace discovers its own project configuration and skills.
		local config = if cwd == env.cwd then " --config " .. launch.quote(env.config) else ""
		local pane = cx.agents:start({ prompt = current.prompt, cwd = cwd, how = "tab",
			command = launch.quote(launch.program()) .. " --cwd " .. launch.quote(cwd) .. " --allow-home" .. config })
		bridge.bind(pane, id, request_id)
		bridge.update(id, request_id, { pane = pane, state = "working", began = false, result = false })
		-- Names/colours are conveniences; their failure cannot lose a started task.
		pcall(function()
			local tab = cx.session:tab_of(pane)
			if tab then
				if type(current.title) == "string" and current.title ~= "" then cx.layout:name_tab(tab, current.title) end
				cx.layout:color_tab(tab, "blue")
			end
		end)
	end)
	if not ok then
		bridge.update(id, request_id, { state = "closed" })
		cx:toast("error", "无法开始任务", tostring(err))
	end
	return { handled = true }
end
tern.route.link(open_task)

-- Tasks a bot command started open here within a couple of seconds, whether or
-- not a workbench is showing. The launch claim in open_task keeps it once-only.
local AUTO_OPEN_MS = 2000
local function open_started(cx)
	if cx then
		for id, request_id in bridge.auto_pending() do
			local current = bridge.task(id)
			if current and current.request_id == request_id and current.state == "starting" and not current.launched then
				pcall(open_task, { url = bridge.LINK .. id }, cx)
			end
		end
	end
	tern.timer(AUTO_OPEN_MS, open_started)
end
tern.timer(AUTO_OPEN_MS, open_started)

local function lifecycle(ev, cx)
	local binding = bridge.binding(ev.pane)
	if not binding then return end
	local current = bridge.task(binding.id)
	if current and current.request_id == binding.request_id then
		local agent = if ev.new == "idle" then agent_at(cx, ev.pane) else nil
		local patch = task_rules.transition(current, ev.new, agent and agent.last_message)
		if patch then bridge.update(binding.id, binding.request_id, patch) end
	else bridge.clear_orphan(binding.id) end
end
tern.on("agent_state", lifecycle)

tern.on("pane_closed", function(ev, _cx)
	local binding = bridge.binding(ev.pane)
	if not binding then return end
	bridge.unbind(ev.pane)
	local current = bridge.task(binding.id)
	if current and current.request_id == binding.request_id then
		local patch = task_rules.transition(current, "pane_closed", nil)
		if patch then bridge.update(binding.id, binding.request_id, patch) end
	else bridge.clear_orphan(binding.id) end
end)

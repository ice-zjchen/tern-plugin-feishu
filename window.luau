local tern = require("tern")
local runtime = require("./lib/runtime")

tern.command({
	id = "inbox",
	title = "飞书 Feishu / Lark：打开工作台",
	keys = { "ctrl+alt+shift+f" },
	run = function(cx)
		if not cx:new_block("tern-plugin-feishu.inbox", {}, "tab") then
			cx:toast("error", "飞书插件未就绪", "请确认当前主机已安装 tern-plugin-feishu 插件。")
		end
	end,
})

tern.command({
	id = "open",
	title = "飞书 Feishu / Lark：查看 @我的消息",
	run = function(cx)
		if not cx:new_block("tern-plugin-feishu.mentions", {}, "tab") then
			cx:toast("error", "飞书插件未就绪", "请确认当前主机已安装 tern-plugin-feishu 插件。")
		end
	end,
})

local function setting(id: string, title: string, key: string, placeholder: string)
	tern.command({
		id = id,
		title = title,
		run = function(cx)
			cx:prompt({ placeholder = placeholder, value = tern.kv.get(key) or "" }):next(function(value, err, nextCx)
				if err then
					if nextCx then nextCx:toast("error", "无法保存", err) end
				elseif value ~= nil then
					tern.kv.set(key, if value == "" then nil else value)
					if nextCx then nextCx:toast("success", "已保存", "新的分析会使用这个设置。") end
				end
			end)
		end,
	})
end

setting("agent", "飞书 Feishu / Lark：设置 AI 程序路径", "agent", "AI 程序可执行文件路径（留空自动查找）")

-- Which task each omp tab belongs to. Only this half writes it.
local function panes(): { [string]: string }
	local stored = tern.kv.get("task_panes")
	return if type(stored) == "table" then stored else {}
end

-- Records a task's state; the block picks it up when it next looks.
local function update(id: string, change: { [string]: any })
	local task = runtime.task(id)
	if task then
		for k, v in change do
			task[k] = v
		end
		runtime.set_task(id, task)
	end
end

local function open_block(cx: any, pane: number): any
	for _, block in cx.agents:list() do
		if block.pane == pane then
			return block
		end
	end
	return nil
end

-- The block runs in the host half, which can't open agents. It asks through a
-- link instead, with the task itself in the plugin's store: only an id gets
-- through this pattern. A task whose tab is still open goes back to that tab.
tern.route.link(function(link, cx)
	local id = string.match(link.url, "^tern%-plugin%-feishu://task/([%w_%-]+)$")
	if not id then
		return nil
	end
	local ok, err = pcall(function()
		local task = runtime.task(id)
		assert(task, "这条消息的任务已不存在")
		local open = if type(task.pane) == "number" then open_block(cx, task.pane) else nil
		if open and open.state ~= "exited" then
			cx.layout:focus(task.pane)
			return
		end
		-- Only a start you asked for opens a tab; a jump to a closed one must not run
		-- the task a second time.
		if task.state ~= "starting" then
			update(id, { state = "closed" })
			return
		end
		local configured = tern.kv.get("agent")
		local program = if type(configured) == "string" and configured ~= "" then configured else "omp"
		local launch = runtime.prepare()
		if launch.warning then
			cx:toast("info", "工作目录已回退", launch.warning)
		end
		local cwd = runtime.task_workspace(task.prompt, launch.cwd)
		-- A different workspace must discover its own config, skills and rules.
		local config = if cwd == launch.cwd then " --config " .. runtime.quote(launch.config) else ""
		-- A normal session in omp's own store, so it outlives the workbench's.
		local pane = cx.agents:start({
			prompt = task.prompt,
			cwd = cwd,
			command = runtime.quote(program) .. " --cwd " .. runtime.quote(cwd) .. " --allow-home" .. config,
			how = "tab",
		})
		-- A name is a convenience: failing to set it must not fail the started task.
		pcall(function()
			local tab = cx.session:tab_of(pane)
			if tab and type(task.title) == "string" and task.title ~= "" then
				cx.layout:name_tab(tab, task.title)
			end
		end)
		local map = panes()
		map[tostring(pane)] = id
		tern.kv.set("task_panes", map)
		update(id, { pane = pane, state = "working", began = false, result = false })
	end)
	if not ok then
		update(id, { state = "closed" })
		cx:toast("error", "无法开始任务", tostring(err))
	end
	return { handled = true }
end)

-- A turn that ended counts as done only if it began: a new tab is idle first.
tern.on("agent_state", function(ev: any, cx: any)
	local id = panes()[tostring(ev.pane)]
	local task = if id then runtime.task(id :: string) else nil
	if not task then
		return
	end
	if ev.new == "working" then
		update(id :: string, { state = "working", began = true })
	elseif ev.new == "waiting_input" then
		update(id :: string, { state = "waiting", began = true })
	elseif ev.new == "exited" then
		update(id :: string, { state = "closed" })
	elseif ev.new == "idle" and task.began then
		local block = open_block(cx, ev.pane)
		update(id :: string, { state = "done", result = block and block.last_message or false })
	end
end)

tern.on("pane_closed", function(ev: any, _cx: any)
	local map = panes()
	local id = map[tostring(ev.pane)]
	if id then
		map[tostring(ev.pane)] = nil
		tern.kv.set("task_panes", map)
		local task = runtime.task(id)
		if task and task.state ~= "done" then
			update(id, { state = "closed" })
		end
	end
end)

tern.command({
	id = "cli",
	title = "飞书 Feishu / Lark：设置 lark-cli 路径",
	run = function(cx)
		cx:prompt({
			placeholder = "lark-cli 可执行文件路径（留空使用 PATH）",
			value = tern.kv.get("cli") or "",
		}):next(function(value, err, nextCx)
			if err then
				if nextCx then nextCx:toast("error", "无法设置路径", err) end
			elseif value ~= nil then
				tern.kv.set("cli", if value == "" then nil else value)
				if nextCx then nextCx:toast("success", "路径已保存", "在消息面板中按 R 刷新生效；远程主机使用该主机的配置。") end
			end
		end)
	end,
})

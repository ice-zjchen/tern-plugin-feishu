local tern = require("tern")
local runtime = require("./lib/runtime")

tern.command({
	id = "inbox",
	title = "飞书：打开工作台",
	keys = { "ctrl+alt+shift+f" },
	run = function(cx)
		if not cx:new_block("tern-plugin-feishu.inbox", {}, "tab") then
			cx:toast("error", "飞书插件未就绪", "请确认当前主机已安装 tern-plugin-feishu 插件。")
		end
	end,
})

tern.command({
	id = "open",
	title = "飞书：查看 @我的消息",
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

setting("agent", "飞书：设置 omp 路径", "agent", "omp 可执行文件路径（留空自动查找）")

-- The block runs in the host half, which can't open agents. It asks through a
-- link instead; only a session id gets through this pattern.
tern.route.link(function(link, cx)
	local session = string.match(link.url, "^tern%-plugin%-feishu://omp/([%w%-]+)$")
	if not session then
		return nil
	end
	local configured = tern.kv.get("agent")
	local program = if type(configured) == "string" and configured ~= "" then configured else "omp"
	local ok, err = pcall(function()
		local launch = runtime.prepare()
		if launch.warning then
			cx:toast("info", "omp 工作目录已回退", launch.warning)
		end
		-- Use the workspace's normal tools and approval policy, as headless does.
		cx.agents:start({
			prompt = "我打开了这条飞书消息的工作会话。按当前 Workspace 的指令、技能和工具策略继续，不沿用历史只读能力声明。先简述实际已完成的工作和待确认事项，然后等我提问；不要仅因打开会话就提交外部操作。",
			cwd = launch.cwd,
			command = runtime.quote(program) .. " --session-dir " .. runtime.quote(launch.sessions)
				.. " --cwd " .. runtime.quote(launch.cwd) .. " --allow-home"
				.. " --config " .. runtime.quote(launch.config) .. " --resume " .. runtime.quote(session),
			how = "split",
		})
	end)
	if not ok then
		cx:toast("error", "无法打开 omp", tostring(err))
	end
	return { handled = true }
end)

tern.command({
	id = "cli",
	title = "飞书：设置 lark-cli 路径",
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

-- Shared by headless turns and the window's native omp launcher.
local tern = require("tern")
local settings = require("./settings")

local runtime = {}

local function absolute(path: string, base: string): string
	local home = tern.getenv("HOME")
	if path == "~" or string.sub(path, 1, 2) == "~/" then
		assert(home, "无法解析 ~：HOME 未设置")
		return home .. string.sub(path, 2)
	end
	return if string.sub(path, 1, 1) == "/" then path else base .. "/" .. path
end

function runtime.prepare(): any
	local workspace = settings.get("workspace")
	local cwd = if workspace == "" then tern.plugin.data else absolute(workspace, tern.plugin.data)
	local warning: string? = nil
	local fallback = workspace ~= "" and not tern.fs.exists(cwd)
	if fallback then
		warning = "Workspace 不存在：" .. cwd .. "；已回退到插件数据目录：" .. tern.plugin.data
		cwd = tern.plugin.data
	end
	assert(pcall(tern.fs.list, cwd), "无法读取 Workspace 目录：" .. cwd)
	local config: any = {}
	local skills = settings.get("skills_dir")
	if skills ~= "" then
		local relative = string.sub(skills, 1, 1) ~= "/" and skills ~= "~" and string.sub(skills, 1, 2) ~= "~/"
		if fallback and relative then
			warning ..= "；已跳过原 Workspace 的相对 Skills 目录：" .. skills
		else
			local directory = absolute(skills, cwd)
			if fallback and not tern.fs.exists(directory) then
				warning ..= "；已跳过不存在的 Skills 目录：" .. directory
			else
				assert(pcall(tern.fs.list, directory), "无法读取 Skills 目录：" .. directory)
				config.skills = { customDirectories = { directory } }
			end
		end
	end
	local path = tern.plugin.data .. "/omp-runtime.yml"
	-- JSON is also valid YAML, including paths containing spaces and quotes.
	tern.fs.write(path, tern.json.encode(config))
	return {
		cwd = cwd, config = path, sessions = tern.plugin.data .. "/sessions", warning = warning,
		skills = config.skills and config.skills.customDirectories[1],
	}
end

-- A GUI-started daemon's PATH is only /usr/bin:/bin:…, and omp's tools inherit it,
-- so the model could not run lark-cli or node. The inherited PATH keeps precedence
-- over the fallbacks; only the configured lark-cli's folder goes ahead of it.
function runtime.path(): string
	local dirs: { string } = {}
	local seen = {}
	local function add(dir: string?)
		if dir and not seen[dir] and tern.fs.exists(dir) then
			seen[dir] = true
			table.insert(dirs, dir)
		end
	end
	local cli = tern.kv.get("cli")
	if type(cli) == "string" then
		add(string.match(cli, "^(/.+)/[^/]+$"))
	end
	for dir in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		add(dir)
	end
	local home = tern.getenv("HOME")
	if home then
		add(home .. "/.local/share/fnm/aliases/default/bin")
		add(home .. "/.local/bin")
	end
	add("/opt/homebrew/bin")
	add("/usr/local/bin")
	return table.concat(dirs, ":")
end

-- A message's omp task, kept where both halves of the plugin can read it and
-- where a reload can't lose it. One key each, so the halves never overwrite
-- each other's tasks.
function runtime.task(id: string): any
	local stored = tern.kv.get("task:" .. id)
	return if type(stored) == "table" then stored else nil
end

function runtime.set_task(id: string, task: any)
	tern.kv.set("task:" .. id, task)
end

-- Read only the confirmed task's first line, never third-party message context.
-- Paths must match the workspace-owned registry exactly.
function runtime.attached_dirs(prompt: string, cwd: string): { string }
	local task = string.match(prompt, "\n## 任务\n(.-)\n\n## 飞书消息")
	local line = task and string.match(task, "^附加仓库：([^\n]+)")
	if not line then return {} end
	local ok, registry = pcall(tern.fs.read, cwd .. "/workspaces.md")
	assert(ok, "无法读取附加仓库清单 workspaces.md")
	local allowed = {}
	for directory in string.gmatch(registry, "`(/[^`\n]+)`") do
		allowed[directory] = true
	end
	local dirs, seen = {}, {}
	for part in string.gmatch(line, "[^;]+") do
		local directory = string.match(part, "^%s*(.-)%s*$")
		assert(allowed[directory], "不在 workspaces.md 中的附加仓库：" .. directory)
		assert(pcall(tern.fs.list, directory), "附加仓库不存在或不可读：" .. directory)
		if not seen[directory] then
			seen[directory] = true
			table.insert(dirs, directory)
		end
	end
	assert(#dirs <= 2, "最多附加两个仓库")
	return dirs
end

-- cx.agents:start accepts a command string, unlike process.run's argv.
function runtime.quote(value: string): string
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

return runtime

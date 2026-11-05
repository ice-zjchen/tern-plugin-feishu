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
	return { cwd = cwd, config = path, sessions = tern.plugin.data .. "/sessions", warning = warning }
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

-- cx.agents:start accepts a command string, unlike process.run's argv.
function runtime.quote(value: string): string
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

return runtime

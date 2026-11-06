-- Loads prompts/<file>.md once per VM and renders a named block.
local tern = require("tern")
local template = require("../shared/template")

local prompts = {}

local loaded: { [string]: template.Blocks } = {}

local function blocks(file: string): template.Blocks
	local cached = loaded[file]
	if not cached then
		-- Relative paths resolve against the plugin directory.
		cached = template.parse(tern.fs.read("prompts/" .. file .. ".md"))
		loaded[file] = cached
	end
	return cached
end

-- The block `name` of prompts/<file>.md with `vars` filled in.
function prompts.render(file: string, name: string, vars: { [string]: string }?): string
	local body = blocks(file)[name]
	assert(body, "缺少提示词：prompts/" .. file .. ".md 的 " .. name)
	return template.render(body, vars)
end

return prompts

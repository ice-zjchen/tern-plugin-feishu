--!strict
-- Prompt templates: Markdown files split into named blocks by `<!-- @name -->`
-- lines; text before the first marker is the block `main`. `{{name}}` places a
-- value. Substitution is a single pass, so values (message text) are never
-- scanned for placeholders themselves.

local template = {}

export type Blocks = { [string]: string }

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function template.parse(source: string): Blocks
	local blocks: Blocks = {}
	local name, lines = "main", {} :: { string }
	local function close()
		local body = trim(table.concat(lines, "\n"))
		if body ~= "" then
			assert(blocks[name] == nil, "提示词块重复：" .. name)
			blocks[name] = body
		end
	end
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		local marker = string.match(line, "^%s*<!%-%-%s*@([%w_%-%.]+)%s*%-%->%s*$")
		if marker then
			close()
			name, lines = marker, {}
		else
			table.insert(lines, line)
		end
	end
	close()
	return blocks
end

-- Fills every `{{name}}`. A placeholder without a value is an error, and so is a
-- value no placeholder uses: either means the template and the code disagree.
function template.render(body: string, vars: { [string]: string }?): string
	local given = vars or {}
	local used: { [string]: boolean } = {}
	local out = string.gsub(body, "{{([%w_]+)}}", function(key: string): string
		local value = given[key]
		assert(value ~= nil, "提示词缺少变量：" .. key)
		used[key] = true
		return value :: string
	end)
	for key in given do
		assert(used[key], "提示词没有使用变量：" .. key)
	end
	return out
end

return template

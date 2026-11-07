-- Selected pictures go directly to @vision once. Reuse downloaded image files;
-- no observation database, content hashes, frozen copies or task-result cache.
local tern = require("tern")
local lark = require("./lark")
local omp = require("./omp")
local prompts = require("./prompts")
local settings = require("../shared/settings")
local sources = require("../core/image_sources")
local matter = require("../core/matter")
local markup = require("../shared/markup")

local vision = {}
vision.describe = sources.describe

local function cached_path(key: string): string?
	local stored = tern.kv.get("inbox_snapshot")
	local image = stored and stored.images and stored.images[key]
	if image and type(image.path) == "string" and string.match(image.path, "^images/[%w_.%-]+$")
		and tern.fs.exists(tern.plugin.data .. "/" .. image.path) then return image.path end
	if tern.fs.exists(tern.plugin.data .. "/images") then
		for _, name in tern.fs.list(tern.plugin.data .. "/images") do
			if name == key or string.sub(name, 1, #key + 1) == key .. "." then return "images/" .. name end
		end
	end
	return nil
end

local function readable(path: string): boolean
	local ok, bytes = pcall(tern.fs.read, tern.plugin.data .. "/" .. path, 20 * 1024 * 1024)
	if not ok then return false end
	return string.sub(bytes, 1, 8) == "\137PNG\r\n\26\n" or string.sub(bytes, 1, 3) == "\255\216\255"
		or string.sub(bytes, 1, 6) == "GIF89a" or string.sub(bytes, 1, 6) == "GIF87a"
		or (string.sub(bytes, 1, 4) == "RIFF" and string.sub(bytes, 9, 12) == "WEBP")
end

function vision.assess(m: any, task: string, notice: (string?) -> (), done: ({ any }, number, any, string?) -> ())
	local images, evidence, selected = {}, sources.describe(m, task), {}
	for _, entry in evidence do if entry.selected then table.insert(selected, entry) end end
	if not settings.get("agent_images") then done(evidence, 0, nil, "图片分析已关闭，请开启“把图片发给 AI”或补充图片文字内容。"); return end
	if #selected > 3 then done(evidence, 0, nil, "本次最多查看 3 张图片，请明确任务需要的图片。"); return end
	local function load(at: number)
		if at > #selected then
			local input = { task = task, trigger = { message_id = m.latest_id or m.id, content = markup.clean(m.content) },
				thread = matter.agent_thread(m), images = selected }
			omp.turn({ purpose = "vision", ephemeral = true, images = images,
				prompt = prompts.render("vision", "assess_turn", { input = tern.json.encode(input, true) }) }, notice,
				function(said, _session, cost, err)
					if err then done(evidence, cost, nil, err); return end
					local result = omp.json_in(said or "")
					if not result or result.image_received ~= true then
						done(evidence, cost, nil, "视觉模型没有确认看到图片，请补充图片内容后重试。")
						return
					end
					for _, entry in selected do entry.status = "inspected" end
					done(evidence, cost, result, nil)
				end)
			return
		end
		local entry = selected[at]
		local function ready(path, err)
			if err or not path or not readable(path) then
				entry.status = "failed"
				done(evidence, 0, nil, err or "图片未能读取，请补充可读图片或文字内容。")
				return
			end
			table.insert(images, path)
			load(at + 1)
		end
		local path = cached_path(entry.file_key)
		if path then ready(path, nil) else lark.download_image(entry.source_message_id, entry.file_key, ready) end
	end
	load(1)
end

return vision

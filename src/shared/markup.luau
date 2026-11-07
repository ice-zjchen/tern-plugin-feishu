--!strict
-- CLI image markers may be Markdown `![Image](img_xxx)` or `[Image: img_xxx]`.
-- Keep their order and identity; mentions of everyone have several forms too.

local markup = {}

local IMAGE = "!%[[^%]]*%]%((img_[%w_%-]+)%)"
local IMAGE_LABEL = "%[Image:%s*(img_[%w_%-]+)%s*%]"

-- The image keys in a message, at most `limit`, without repeats.
function markup.images(content: string, limit: number): { string }
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	local cursor = 1
	while #keys < limit do
		local first, last, key = string.find(content, IMAGE, cursor)
		local label_first, label_last, label_key = string.find(content, IMAGE_LABEL, cursor)
		if label_first and (not first or label_first < first) then
			first, last, key = label_first, label_last, label_key
		end
		if not first or not last or not key then break end
		cursor = (last :: number) + 1
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	return keys
end

-- The text with each image replaced by a readable mark.
function markup.clean(content: string): string
	return (string.gsub(string.gsub(content, IMAGE, "[图片]"), IMAGE_LABEL, "[图片]"))
end

-- Whether the text mentions everyone, in any of the forms the CLI writes.
function markup.mentions_all(content: string): boolean
	return string.find(content, "@_all", 1, true) ~= nil
		or string.find(content, '<at user_id="all"', 1, true) ~= nil
		or string.find(content, "@everyone", 1, true) ~= nil
end

return markup

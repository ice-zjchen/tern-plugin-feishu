--!strict
-- Message text as lark-cli writes it: images as `![Image](img_xxx)`, mentions of
-- everyone in one of several forms.

local markup = {}

local IMAGE = "!%[[^%]]*%]%((img_[%w_%-]+)%)"

-- The image keys in a message, at most `limit`, without repeats.
function markup.images(content: string, limit: number): { string }
	local keys: { string } = {}
	for key in string.gmatch(content, IMAGE) do
		if #keys < limit and not table.find(keys, key) then
			table.insert(keys, key)
		end
	end
	return keys
end

-- The text with each image replaced by a readable mark.
function markup.clean(content: string): string
	return (string.gsub(content, IMAGE, "[图片]"))
end

-- Whether the text mentions everyone, in any of the forms the CLI writes.
function markup.mentions_all(content: string): boolean
	return string.find(content, "@_all", 1, true) ~= nil
		or string.find(content, '<at user_id="all"', 1, true) ~= nil
		or string.find(content, "@everyone", 1, true) ~= nil
end

return markup

-- Text editing for fields whose text the block owns. Tern's cursor and edit
-- offsets are UTF-16 code units; Luau strings are UTF-8 bytes.

local edit = {}

local function units(codepoint: number): number
	return if codepoint > 0xFFFF then 2 else 1
end

function edit.len(text: string): number
	local n = 0
	for _, c in utf8.codes(text) do
		n += units(c)
	end
	return n
end

-- The byte index (1-based) at UTF-16 offset `offset`, clamped to the text.
local function byte_at(text: string, offset: number): number
	local n = 0
	for at, c in utf8.codes(text) do
		if n >= offset then
			return at
		end
		n += units(c)
	end
	return #text + 1
end

-- `text` with UTF-16 range from..to replaced by `insert`.
function edit.splice(text: string, from: number, to: number, insert: string): string
	return string.sub(text, 1, byte_at(text, from) - 1) .. insert .. string.sub(text, byte_at(text, to))
end

-- The UTF-16 offset one character before or after `offset`.
function edit.step(text: string, offset: number, direction: number): number
	local n = 0
	for _, c in utf8.codes(text) do
		local after = n + units(c)
		if direction < 0 and after >= offset then
			return n
		elseif direction > 0 and n >= offset then
			return after
		end
		n = after
	end
	return n
end

-- A key press applied to `field` ({text, cursor}). Returns whether it changed
-- the field or its caret; Enter, Tab and Escape stay with the caller.
function edit.key(field: { text: string, cursor: number }, key: any): boolean
	local text, cursor = field.text, field.cursor
	if key.name == "paste" then
		local pasted = tostring(key.text or "")
		field.text = edit.splice(text, cursor, cursor, pasted)
		field.cursor = cursor + edit.len(pasted)
	elseif key.name == "backspace" then
		local before = edit.step(text, cursor, -1)
		field.text = edit.splice(text, before, cursor, "")
		field.cursor = before
	elseif key.name == "delete" then
		field.text = edit.splice(text, cursor, edit.step(text, cursor, 1), "")
	elseif key.name == "left" then
		field.cursor = edit.step(text, cursor, -1)
	elseif key.name == "right" then
		field.cursor = edit.step(text, cursor, 1)
	elseif key.name == "home" then
		field.cursor = 0
	elseif key.name == "end" then
		field.cursor = edit.len(text)
	elseif type(key.text) == "string" and key.text ~= "" and not key.ctrl and not key.meta then
		field.text = edit.splice(text, cursor, cursor, key.text)
		field.cursor = cursor + edit.len(key.text)
	else
		return false
	end
	return true
end

return edit

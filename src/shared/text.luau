--!strict
-- Text helpers shared by every layer. Tern's caret and edit offsets are UTF-16
-- code units; Luau strings are UTF-8 bytes.

local text = {}

local function units(codepoint: number): number
	return if codepoint > 0xFFFF then 2 else 1
end

-- Length in UTF-16 code units.
function text.len(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += units(c)
	end
	return n
end

-- The byte index (1-based) at UTF-16 offset `offset`, clamped to the text.
local function byte_at(s: string, offset: number): number
	local n = 0
	for at, c in utf8.codes(s) do
		if n >= offset then
			return at
		end
		n += units(c)
	end
	return #s + 1
end

-- `s` with the UTF-16 range from..to replaced by `insert`.
function text.splice(s: string, from: number, to: number, insert: string): string
	return string.sub(s, 1, byte_at(s, from) - 1) .. insert .. string.sub(s, byte_at(s, to))
end

-- The UTF-16 offset one character before (`direction` < 0) or after `offset`.
function text.step(s: string, offset: number, direction: number): number
	local n = 0
	for _, c in utf8.codes(s) do
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

export type Field = { text: string, cursor: number }
export type Key = { name: string, text: string?, ctrl: boolean?, meta: boolean? }

-- Applies a key press to `field`. Returns whether the text or caret changed;
-- Enter, Tab and Escape stay with the caller.
function text.key(field: Field, key: Key): boolean
	local s, cursor = field.text, field.cursor
	local typed = key.text
	if key.name == "paste" then
		local pasted = typed or ""
		field.text = text.splice(s, cursor, cursor, pasted)
		field.cursor = cursor + text.len(pasted)
	elseif key.name == "backspace" then
		local before = text.step(s, cursor, -1)
		field.text = text.splice(s, before, cursor, "")
		field.cursor = before
	elseif key.name == "delete" then
		field.text = text.splice(s, cursor, text.step(s, cursor, 1), "")
	elseif key.name == "left" then
		field.cursor = text.step(s, cursor, -1)
	elseif key.name == "right" then
		field.cursor = text.step(s, cursor, 1)
	elseif key.name == "home" then
		field.cursor = 0
	elseif key.name == "end" then
		field.cursor = text.len(s)
	elseif typed ~= nil and typed ~= "" and not key.ctrl and not key.meta then
		field.text = text.splice(s, cursor, cursor, typed)
		field.cursor = cursor + text.len(typed)
	else
		return false
	end
	return true
end

-- Runs of whitespace as single spaces, without leading or trailing ones.
function text.flat(s: string): string
	return (string.gsub(string.gsub(s, "%s+", " "), "^ ?(.-) ?$", "%1"))
end

-- At most `chars` characters, then an ellipsis.
function text.clip(s: string, chars: number): string
	local at = utf8.offset(s, chars + 1)
	return if at then string.sub(s, 1, at - 1) .. "…" else s
end

-- Display cells: CJK and full-width characters take two.
function text.cells(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += if c >= 0x1100 then 2 else 1
	end
	return n
end

-- Flattened, then cut to fit `cells` display cells with an ellipsis.
function text.fit(s: string, cells: number): string
	local flat = text.flat(s)
	if text.cells(flat) <= cells then
		return flat
	end
	local out, n = {}, 0
	for _, c in utf8.codes(flat) do
		local w = if c >= 0x1100 then 2 else 1
		if n + w > cells - 1 then
			break
		end
		table.insert(out, utf8.char(c))
		n += w
	end
	return table.concat(out) .. "…"
end

-- Only Feishu/Lark chat-open applinks are opened; a message cannot supply a protocol.
function text.is_chat_link(link: any): boolean
	return type(link) == "string" and (
		string.match(link, "^https://applink%.feishu%.cn/client/chat/open%?") ~= nil
		or string.match(link, "^https://applink%.larksuite%.com/client/chat/open%?") ~= nil
	)
end

return text

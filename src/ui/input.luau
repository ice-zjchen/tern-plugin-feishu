-- UI event decoding only: stable control paths become domain intents. Character
-- editing and state transitions belong to core/update, never to DOM callbacks.
local ids = require("./ids")
local schema = require("../shared/schema")
local views = require("../core/views")
local keymap = require("../shared/keymap")

local input = {}

function input.event(model: any, ev: any): any
	if model.dialog then
		return if ev.ev == "action" and ev.act == "close-thread" then { type = "action", name = "close-thread" } else nil
	end
	if ev.ev == "action" and type(ev.act) == "string" then
		local name = string.match(ev.act, "^history%-(.+)$")
		if name then return { type = "history", name = name } end
		return { type = "action", name = ev.act, value = ev.value }
	elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
		if model.page == "history" then return { type = "history", name = "select", index = tonumber(ev.item), open = ev.ev == "activate" } end
		if string.sub(ev.item, 1, #ids.QUEUE_PREFIX) ~= ids.QUEUE_PREFIX then return nil end
		return { type = "select", id = string.sub(ev.item, #ids.QUEUE_PREFIX + 1), open = ev.ev == "activate" }
	elseif ev.ev == "change" and type(ev.id) == "string" then
		local id = string.match(ev.id, "%.f_([%w_]+)%.c$")
		if id and schema.known(id) then return { type = "setting", setting = id, value = ev.value == true } end
	elseif ev.ev == "focus" then
		local setting = type(ev.id) == "string" and string.match(ev.id, "%.f_([%w_]+)%.wrap%.c$")
		if setting and schema.known(setting) then return { type = "focus", mode = "setting", setting = setting }
		elseif ev.id == ids.COMMAND_ID then return { type = "focus", mode = "command" }
		elseif ev.id == ids.DRAFT_ID then return { type = "focus", mode = "draft" } end
	end
	return nil
end


function input.key(model: any, key: any): any
	if model.dialog then return if key.name == "escape" then { type = "action", name = "close-thread" } else nil end
	if model.mode then return { type = "field-key", key = key } end
	if key.ctrl or key.meta or key.alt then return nil end
	local k = key.text or key.name
	if model.page == "settings" then
		if key.name == "escape" or k == "," then return { type = "settings-close" }
		elseif key.name == "down" or k == "j" then return { type = "settings-move", direction = 1 }
		elseif key.name == "up" or k == "k" then return { type = "settings-move", direction = -1 }
		elseif key.name == "enter" or key.name == "space" then return { type = "settings-activate" }
		elseif key.name == "right" or k == "l" then return { type = "settings-activate", direction = 1 }
		elseif key.name == "left" or k == "h" then return { type = "settings-activate", direction = -1 } end
		return nil
	end
	if model.page == "history" then
		if k == "j" or key.name == "down" then return { type = "history", name = "move", direction = 1 }
		elseif k == "k" or key.name == "up" then return { type = "history", name = "move", direction = -1 }
		elseif k == "r" or k == "R" or key.name == "f5" then return { type = "history", name = "refresh" }
		elseif k == "n" or key.name == "right" then return { type = "history", name = "next" }
		elseif k == "p" or key.name == "left" then return { type = "history", name = "previous" }
		elseif k == "c" then return { type = "history", name = "copy-message" }
		elseif key.name == "enter" then return { type = "history", name = "open-message" }
		elseif k == "," then return { type = "action", name = "settings" }
		elseif string.match(k, "^[1-5]$") then return { type = "action", name = "view", value = views.LIST[tonumber(k) :: number].id } end
		return nil
	end
	if key.name == "down" or k == "j" then return { type = "move", direction = 1 }
	elseif key.name == "up" or k == "k" then return { type = "move", direction = -1 }
	elseif k == "/" then return { type = "focus", mode = "command" }
	elseif k == "6" or k == "7" then
		local source = if k == "6" then "mention" else "dm"
		return { type = "action", name = "source", value = if model.source == source then "all" else source }
	elseif string.match(k, "^[1-5]$") then
		return { type = "action", name = "view", value = views.LIST[tonumber(k) :: number].id }
	end
	local action = keymap.action(k) or keymap.action(key.name)
	return if action then { type = "action", name = action } else nil
end

return input

--!strict
-- One catalogue for workbench shortcuts and their dock hints. Context-sensitive
-- keys (navigation, settings, editing) are decoded by ui/input.
local keymap = {}

export type Binding = { key: string, action: string, value: string?, hint: string?, adjust: boolean?, narrow: boolean? }
local bindings: { Binding } = {
	{ key = "a", action = "primary", hint = "下一步", narrow = true },
	{ key = "e", action = "edit", hint = "修改", adjust = true },
	{ key = "/", action = "adjust", hint = "让 AI 调整", adjust = true },
	{ key = "o", action = "open-task", hint = "手动开任务" },
	{ key = "r", action = "redraft" }, { key = "c", action = "copy" }, { key = "s", action = "snooze" },
	{ key = "x", action = "archive" }, { key = "u", action = "undo" },
	{ key = "R", action = "refresh" }, { key = "f5", action = "refresh" }, { key = "m", action = "load-more" },
	{ key = "*", action = "star" }, { key = "enter", action = "open" }, { key = ",", action = "settings" },
	{ key = "g", action = "force" }, { key = "i", action = "hide-chat" }, { key = "n", action = "manual-chat" },
	{ key = "h", action = "view", value = "bot", hint = "机器人聚合" }, { key = "p", action = "stop" },
}
local actions: { [string]: Binding } = {}
for _, binding in bindings do actions[binding.key] = binding end

function keymap.action(key: string): (string?, string?)
	local binding = actions[key]
	return if binding then binding.action else nil, if binding then binding.value else nil
end

function keymap.hints(page: string?, adjustable: boolean, narrow: boolean, view: string?): { string }
	if page == "settings" then return { "j/k 上下", "空格 切换", "←/→ 换值", "Esc 返回" } end
	local hints = { "j/k 上下" }
	for _, binding in bindings do
		if binding.hint and (not binding.adjust or adjustable) and (not narrow or binding.narrow) then
			table.insert(hints, binding.key .. " " .. binding.hint)
		end
	end
	if not narrow and view ~= "bot" then table.insert(hints, "6 @我"); table.insert(hints, "7 私聊") end
	return hints
end

return keymap

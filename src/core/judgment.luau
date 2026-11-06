--!strict
-- Model output after JSON decoding. This boundary knows the prompt protocol,
-- not sessions, processes or the workbench's mutable state.
local types = require("./types")

local judgment = {}

export type Change = { kind: types.Kind?, draft: string?, task: string?, risk: string? }

local KIND_OF: { [string]: types.Kind } = { ignore = "fyi", reply = "reply", deep = "deep" }

local function text_of(value: any): string?
	return if type(value) == "string" and string.find(value, "%S") then value else nil
end

local function decision_error(value: any): string
	return "AI 返回的 decision 无效：" .. tostring(value) .. "（应为 ignore、reply 或 deep）。"
end

function judgment.parse(output: any): (types.Judgment?, string?)
	if type(output) ~= "table" then
		return nil, "AI 返回的判断不是 JSON 对象。"
	end
	local kind = if type(output.decision) == "string" then KIND_OF[output.decision] else nil
	if not kind then
		return nil, decision_error(output.decision)
	end
	local task = if type(output.task) == "table" then output.task else {}
	local summary = tostring(output.summary or "")
	return {
		kind = kind,
		pri = if type(output.priority) == "string" and string.match(output.priority, "^P[0-3]$") then output.priority else "P2",
		summary = summary,
		why = tostring(output.why or ""),
		draft = text_of(output.draft) or "",
		risk = text_of(output.risk) or "",
		task = { title = text_of(task.title) or summary, prompt = text_of(task.prompt) or summary },
		manual = false,
	}, nil
end

-- Empty draft/task fields mean no edit in the conversation protocol. A rewritten
-- task always carries its new risk, including an empty string to clear an old one.
function judgment.change(output: any): (string?, Change?, string?)
	if type(output) ~= "table" then
		return nil, nil, "AI 返回的对话不是 JSON 对象。"
	end
	local kind = nil
	if output.decision ~= nil and output.decision ~= "" then
		kind = if type(output.decision) == "string" then KIND_OF[output.decision] else nil
		if not kind then
			return nil, nil, decision_error(output.decision)
		end
	end
	local task = text_of(output.task)
	local risk = text_of(output.risk)
	return tostring(output.reply or ""), {
		kind = kind,
		draft = text_of(output.draft),
		task = task,
		risk = if task then risk or "" else risk,
	}, nil
end

return judgment

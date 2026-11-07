--!strict
-- A tool result is usable only for a submitted eval judge call. Assistant text
-- and unrelated tool results cannot supply the context choice. New attempts
-- invalidate older evidence, including when the new attempt fails.
local trace = {}
export type State = { calls: { [string]: boolean }, current: string?, answer: any }
function trace.new(): State
	return { calls = {} }
end
function trace.call(state: State, call: any)
	local args = call.arguments
	if call.name == "eval" and type(call.id) == "string" and type(args) == "table" and type(args.code) == "string"
		and string.find(args.code, "%f[%w]judge%s*%(") then
		state.calls[call.id], state.current, state.answer = true, call.id, nil
	end
end
function trace.result(state: State, id: string?, failed: boolean, value: any)
	if id == nil or id ~= state.current or not state.calls[id] then return end
	state.answer = if not failed and type(value) == "table"
		and type(value.materials) == "table" and type(value.discussion) == "table" then value else nil
end
return trace

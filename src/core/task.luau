--!strict
-- Task-tab launch and lifecycle rules, independent of Tern and storage.
local task = {}

-- Execution routing accepts only the confirmed structured field, never Markdown.
function task.valid_workspace(value: any): boolean
	return type(value) == "string" and (value == "" or string.sub(value, 1, 1) == "/")
		and not string.find(value, "[%c]")
end

function task.workspace(workspace: string, default: string): string
	assert(task.valid_workspace(workspace), "执行 Workspace 必须为空或绝对路径")
	return if workspace == "" then default else workspace
end

-- The trusted workspace registry's second column is a backtick-quoted absolute path.
function task.allowed(directory: string, default: string, registry: string): boolean
	if directory == default then return true end
	for line in string.gmatch(registry .. "\n", "([^\n]*)\n") do
		local candidate = string.match(line, "^%s*|[^|\n]+|%s*`(/[^`\n]+)`%s*|")
		if directory == candidate then return true end
	end
	return false
end

function task.valid_request(request: any): boolean
	return type(request) == "table" and request.version == 2
		and type(request.matter_id) == "string" and request.matter_id ~= ""
		and type(request.revision) == "number" and request.revision >= 0 and request.revision < math.huge and request.revision % 1 == 0
		and type(request.request_id) == "number" and request.request_id > 0 and request.request_id < math.huge and request.request_id % 1 == 0
		and type(request.prompt) == "string" and type(request.title) == "string"
		and type(request.task_text) == "string" and task.valid_workspace(request.workspace)
		and task.valid_workspace(request.default_workspace) and request.default_workspace ~= ""
end

-- The initial idle notification is not the end of a round. Only an attempt that
-- actually worked or waited for input may publish a result.
function task.transition(current: any, event: string, last_message: string?): any
	if event == "working" then return { state = "working", began = true }
	elseif event == "waiting_input" then return { state = "waiting", began = true }
	elseif event == "exited" then return { state = "closed" }
	elseif event == "idle" and current.began then return { state = "done", result = last_message or false }
	elseif event == "pane_closed" and current.state ~= "done" then return { state = "closed" } end
	return nil
end

-- Start is an explicit once-only request. A closed pane, an old link, or a
-- launch interrupted after its claim must not silently run a task again.
function task.route(current: any, live: boolean): string
	if live then return "focus" end
	return if current.state == "starting" and not current.launched then "start" else "closed"
end

-- A stale result is never attached to a new request. The returned view is
-- disposable; neither the host nor the window may write it back as a unit.
function task.join(request: any, state: any): any
	if not request then return nil end
	local view: any = { version = request.version, matter_id = request.matter_id, revision = request.revision,
		prompt = request.prompt, title = request.title, task_text = request.task_text, workspace = request.workspace,
		default_workspace = request.default_workspace,
		request_id = request.request_id, state = if task.valid_request(request) then "starting" else "closed" }
	if state and state.request_id == request.request_id then
		for _, key in { "state", "pane", "began", "launched", "result" } do view[key] = state[key] end
	end
	return view
end

return task

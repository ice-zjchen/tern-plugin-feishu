--!strict
-- Task-tab launch and lifecycle rules, independent of Tern and storage.
local task = {}

-- Only the confirmed task's first line can choose a workspace. Message text,
-- quotes and other Markdown sections are never passed here.
function task.workspace(task_text: string?, default: string): string
	local first = if task_text then string.match(task_text, "^([^\n]*)") or "" else ""
	assert(not string.match(first, "^附加仓库："), "旧附加仓库任务需重新确认执行 Workspace")
	if not string.match(first, "^执行 Workspace：") then return default end
	local directory = string.match(first, "^执行 Workspace：%s*(.-)%s*$") or ""
	assert(directory ~= "", "执行 Workspace 不能为空")
	return directory
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
	local view: any = { prompt = request.prompt, title = request.title, task_text = request.task_text,
		request_id = request.request_id, state = "starting" }
	if state and state.request_id == request.request_id then
		for key, value in state do view[key] = value end
	end
	return view
end

return task

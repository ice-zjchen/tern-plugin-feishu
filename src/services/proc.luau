-- Long or stoppable child processes. tern.process.run returns no handle, so a
-- shell records its PID before exec. Only this VM's active tokens can be stopped.
local tern = require("tern")

local proc = {}
local DIR = "runs"
local runs = 0
local owner = string.format("%.9f", os.clock())
local active: { [string]: { stopping: boolean, retry: any? } } = {}

local function file(name: string): string
	return tern.plugin.data .. "/" .. DIR .. "/" .. name
end

-- Runs argv and returns its stop token; nil when it could not start (`done` is
-- then not called). `done` gets Tern's process result after the PID file is gone.
function proc.run(kind: string, argv: { string }, options: any, done: (any) -> ()): string?
	runs += 1
	local token = kind .. "-" .. tostring(os.time()) .. "-" .. owner .. "-" .. tostring(runs)
	local pids = file(token .. ".pid")
	-- exec keeps the PID, stdin and exit status of the command itself.
	local wrapped = { "/bin/sh", "-c", 'printf %s "$$" > "$0" && exec "$@"', pids }
	for _, arg in argv do table.insert(wrapped, arg) end
	local run: { stopping: boolean, retry: any? } = { stopping = false }
	active[token] = run
	local started = pcall(function()
		tern.fs.mkdir(tern.plugin.data .. "/" .. DIR)
		tern.process.run(wrapped, options, function(result)
			active[token] = nil
			if run.retry then run.retry:cancel(); run.retry = nil end
			pcall(tern.fs.remove, pids)
			done(result)
		end)
	end)
	if not started then active[token] = nil end
	return if started then token else nil
end

local function pid_of(token: string): string?
	local ok, pid = pcall(tern.fs.read, file(token .. ".pid"))
	return if ok and type(pid) == "string" and string.match(pid, "^%d+$") then pid else nil
end

-- Accepts a stop request only for a current-VM run. A request made before the
-- shell records its PID waits for that file, or ends with the run's callback.
-- Old PID files are not process handles: command substrings do not prove ownership.
function proc.stop(token: string): boolean
	local run = active[token]
	if not run then return false end
	if run.stopping then return true end
	run.stopping = true
	local function request()
		run.retry = nil
		if active[token] ~= run then return end
		local pid = pid_of(token)
		if not pid then
			run.retry = tern.timer(10, request)
			return
		end
		-- TERM to the command's own children first, then to the command.
		tern.process.run({ "/bin/sh", "-c", 'pkill -TERM -P "$0"; kill -TERM "$0"', pid }, function() end)
	end
	local accepted = pcall(request)
	if not accepted then run.stopping = false end
	return accepted
end

return proc
